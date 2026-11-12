import Foundation
// TDLibKit predates Swift concurrency, so its types aren't marked Sendable. `TDLibClient`
// is safe to share: requests go through its own dispatch queues and a concurrent dictionary.
@preconcurrency import TDLibKit

/// A Telegram user-client session for talking to Adam's bots.
///
/// Wraps TDLibKit and exposes only the plain value types in `Models.swift`.
/// The app never touches TDLibKit types directly.
///
/// `authStates` and `events` are single-consumer streams created once per instance.
///
/// Create one instance and keep it for the life of the app: once `start()` has run, the
/// TDLib client stays alive for the rest of the process. After `logOut()`, TDLib closes the
/// client and this actor creates a fresh one by itself, so `authStates` continues with
/// `.loggingOut`, `.closed`, `.starting` and `.needsPhoneNumber`. Call `start()` only once.
public actor TelegramLink {
    public nonisolated let authStates: AsyncStream<AuthState>
    public nonisolated let events: AsyncStream<ChatEvent>

    private let config: TelegramConfig
    private let authContinuation: AsyncStream<AuthState>.Continuation
    private let eventContinuation: AsyncStream<ChatEvent>.Continuation

    /// Raw TDLib updates, in arrival order, carried from TDLib's queue into the actor.
    private let updates: AsyncStream<Data>
    private let updateContinuation: AsyncStream<Data>.Continuation
    private let decoder = JSONDecoder()

    private var manager: TDLibClientManager?
    private var client: TDLibClient?
    /// Ends "typing" for a chat when TDLib's action expires without a refresh.
    private var typingTimeouts: [ChatID: Task<Void, Never>] = [:]

    /// TDLib chat actions last about 5 seconds unless refreshed.
    private static let typingTimeout: Duration = .seconds(6)
    /// How many chats from the top of the main chat list `botChats()` looks at.
    private static let chatListLimit = 100

    public init(config: TelegramConfig) {
        self.config = config
        (authStates, authContinuation) = AsyncStream.makeStream(of: AuthState.self)
        (events, eventContinuation) = AsyncStream.makeStream(of: ChatEvent.self)
        (updates, updateContinuation) = AsyncStream.makeStream(of: Data.self)
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    /// Creates the TDLib client and starts the login state machine. Watch `authStates`.
    public func start() async throws {
        guard manager == nil else { return }
        let manager = TDLibClientManager()
        self.manager = manager
        Task {
            for await data in updates {
                handle(data)
            }
        }
        let client = makeClient(manager)
        // TDLib logs verbosely by default; keep only errors.
        _ = try? client.execute(query: DTO(SetLogVerbosityLevel(newVerbosityLevel: 1)))
    }

    // MARK: - Login

    public func submitPhoneNumber(_ phoneNumber: String) async throws {
        try await perform { try await $0.setAuthenticationPhoneNumber(phoneNumber: phoneNumber, settings: nil) }
    }

    public func submitCode(_ code: String) async throws {
        try await perform { try await $0.checkAuthenticationCode(code: code) }
    }

    public func submitPassword(_ password: String) async throws {
        try await perform { try await $0.checkAuthenticationPassword(password: password) }
    }

    public func logOut() async throws {
        try await perform { try await $0.logOut() }
    }

    // MARK: - Chats and messages

    /// Adam's private chats whose peer is a bot.
    public func botChats() async throws -> [BotChat] {
        try await perform { client in
            do {
                try await client.loadChats(chatList: .chatListMain, limit: Self.chatListLimit)
            } catch let error as TDLibKit.Error where error.code == 404 {
                // Every chat in the main list is already loaded.
            }
            let chats = try await client.getChats(chatList: .chatListMain, limit: Self.chatListLimit)
            var bots: [BotChat] = []
            for chatID in chats.chatIds {
                let chat = try await client.getChat(chatId: chatID)
                guard case .chatTypePrivate(let info) = chat.type else { continue }
                let user = try await client.getUser(userId: info.userId)
                if let bot = Mapping.botChat(chat: chat, user: user) {
                    bots.append(bot)
                }
            }
            return bots
        }
    }

    /// The most recent messages in a chat, oldest first.
    public func history(in chat: ChatID, limit: Int) async throws -> [ChatMessage] {
        guard limit > 0 else { return [] }
        return try await perform { client in
            // TDLib returns newest first, often only a few messages per call, so page
            // backwards until there are `limit` messages or no older ones.
            var messages: [Message] = []
            var fromID: Int64 = 0
            while messages.count < limit {
                let batch = try await client.getChatHistory(
                    chatId: chat.rawValue,
                    fromMessageId: fromID,
                    limit: min(100, limit - messages.count),
                    offset: 0,
                    onlyLocal: false
                )
                let older = (batch.messages ?? []).filter { fromID == 0 || $0.id < fromID }
                guard let oldest = older.last else { break }
                messages += older
                fromID = oldest.id
            }
            return messages.reversed().map(Mapping.chatMessage)
        }
    }

    public func sendText(_ text: String, to chat: ChatID) async throws {
        let content = InputMessageContent.inputMessageText(InputMessageText(
            clearDraft: false,
            linkPreviewOptions: nil,
            text: FormattedText(entities: [], text: text)
        ))
        try await send(content, to: chat)
    }

    /// Sends a local image file. TDLib uploads it after this returns, so leave the file
    /// in place until `.sendSucceeded` or `.sendFailed` arrives for the message.
    public func sendPhoto(fileURL: URL, caption: String?, to chat: ChatID) async throws {
        let photo = InputPhoto(
            addedStickerFileIds: [],
            height: 0,
            photo: .inputFileLocal(InputFileLocal(path: fileURL.path(percentEncoded: false))),
            thumbnail: nil,
            video: nil,
            width: 0
        )
        let content = InputMessageContent.inputMessagePhoto(InputMessagePhoto(
            caption: caption.map { FormattedText(entities: [], text: $0) },
            hasSpoiler: false,
            photo: photo,
            selfDestructType: nil,
            showCaptionAboveMedia: false
        ))
        try await send(content, to: chat)
    }

    /// Adds `emoji` to the message if Adam hasn't reacted with it, otherwise removes it.
    public func toggleReaction(_ emoji: String, on message: MessageID, in chat: ChatID) async throws {
        try await perform { client in
            let current = try await client.getMessage(chatId: chat.rawValue, messageId: message.rawValue)
            let isChosen = Mapping.reactions(current.interactionInfo)
                .contains { $0.emoji == emoji && $0.isChosen }
            let reaction = ReactionType.reactionTypeEmoji(ReactionTypeEmoji(emoji: emoji))
            if isChosen {
                try await client.removeMessageReaction(
                    chatId: chat.rawValue,
                    messageId: message.rawValue,
                    reactionType: reaction
                )
            } else {
                try await client.addMessageReaction(
                    chatId: chat.rawValue,
                    isBig: false,
                    messageId: message.rawValue,
                    reactionType: reaction,
                    updateRecentReactions: false
                )
            }
        }
    }

    /// Downloads a file (if needed) and returns its local URL.
    public func downloadFile(_ file: FileRef) async throws -> URL {
        let downloaded = try await perform {
            try await $0.downloadFile(fileId: Int(file.id), limit: 0, offset: 0, priority: 1, synchronous: true)
        }
        guard downloaded.local.isDownloadingCompleted else {
            throw TelegramLinkError.tdlib(code: 0, message: "The download didn't finish.")
        }
        return URL(filePath: downloaded.local.path)
    }

    /// Marks messages as read so other Telegram apps don't show stale unread badges.
    public func markRead(_ messages: [MessageID], in chat: ChatID) async throws {
        guard !messages.isEmpty else { return }
        try await perform {
            try await $0.viewMessages(
                chatId: chat.rawValue,
                forceRead: true,
                messageIds: messages.map(\.rawValue),
                source: nil
            )
        }
    }

    // MARK: - TDLib plumbing

    private func makeClient(_ manager: TDLibClientManager) -> TDLibClient {
        let continuation = updateContinuation
        // TDLib calls this on its own queue; the stream carries updates into the actor in order.
        let client = manager.createClient { @Sendable data, _ in
            continuation.yield(data)
        }
        self.client = client
        return client
    }

    /// Runs a TDLib request and turns TDLib errors into `TelegramLinkError.tdlib`.
    @discardableResult
    private func perform<T>(_ request: (TDLibClient) async throws -> T) async throws -> T {
        guard let client else { throw TelegramLinkError.notStarted }
        do {
            return try await request(client)
        } catch let error as TDLibKit.Error {
            throw TelegramLinkError.tdlib(code: error.code, message: error.message)
        }
    }

    private func send(_ content: InputMessageContent, to chat: ChatID) async throws {
        try await perform {
            try await $0.sendMessage(
                chatId: chat.rawValue,
                inputMessageContent: content,
                options: nil,
                replyMarkup: nil,
                replyTo: nil,
                topicId: nil
            )
        }
    }

    // MARK: - Updates

    private func handle(_ data: Data) {
        // Updates this version of TDLibKit can't decode are ones the app doesn't use.
        guard let update = try? decoder.decode(Update.self, from: data) else { return }
        switch update {
        case .updateAuthorizationState(let update):
            handleAuthorizationState(update.authorizationState)
        case .updateNewMessage(let update):
            eventContinuation.yield(.newMessage(Mapping.chatMessage(update.message)))
        case .updateMessageInteractionInfo(let update):
            eventContinuation.yield(.reactionsChanged(
                chat: ChatID(update.chatId),
                message: MessageID(update.messageId),
                reactions: Mapping.reactions(update.interactionInfo)
            ))
        case .updateChatAction(let update):
            handleChatAction(update.action, in: ChatID(update.chatId))
        case .updateMessageSendSucceeded(let update):
            eventContinuation.yield(.sendSucceeded(
                chat: ChatID(update.message.chatId),
                oldID: MessageID(update.oldMessageId),
                message: Mapping.chatMessage(update.message)
            ))
        case .updateMessageSendFailed(let update):
            eventContinuation.yield(.sendFailed(
                chat: ChatID(update.message.chatId),
                message: MessageID(update.oldMessageId),
                error: update.error.message
            ))
        default:
            break
        }
    }

    private func handleAuthorizationState(_ state: AuthorizationState) {
        authContinuation.yield(Mapping.authState(state))
        switch state {
        case .authorizationStateWaitTdlibParameters:
            setTdlibParameters()
        case .authorizationStateClosed:
            // After a log out TDLib closes the client. Start a fresh one so login can begin again.
            if let manager {
                _ = makeClient(manager)
            }
        default:
            break
        }
    }

    private func setTdlibParameters() {
        guard let client else { return }
        let config = config
        Task {
            do {
                try await client.setTdlibParameters(
                    apiHash: config.apiHash,
                    apiId: Int(config.apiID),
                    applicationVersion: config.applicationVersion,
                    databaseDirectory: config.databaseDirectory.path(percentEncoded: false),
                    databaseEncryptionKey: nil,
                    deviceModel: config.deviceModel,
                    filesDirectory: config.filesDirectory.path(percentEncoded: false),
                    systemLanguageCode: config.systemLanguageCode,
                    systemVersion: config.systemVersion,
                    useChatInfoDatabase: true,
                    useFileDatabase: true,
                    useMessageDatabase: true,
                    useSecretChats: false,
                    useTestDc: false
                )
            } catch {
                // Usually a missing or invalid api_id / api_hash. Login can't go further.
                let message = (error as? TDLibKit.Error)?.message ?? error.localizedDescription
                authContinuation.yield(.unsupported("setTdlibParameters failed: \(message)"))
            }
        }
    }

    private func handleChatAction(_ action: ChatAction, in chat: ChatID) {
        switch action {
        case .chatActionTyping:
            typingTimeouts[chat]?.cancel()
            typingTimeouts[chat] = Task {
                try? await Task.sleep(for: Self.typingTimeout)
                typingExpired(in: chat)
            }
            eventContinuation.yield(.typing(chat: chat, isTyping: true))
        case .chatActionCancel:
            stopTyping(in: chat)
        default:
            break
        }
    }

    private func typingExpired(in chat: ChatID) {
        // A newer typing action cancels this timeout and starts its own.
        guard !Task.isCancelled else { return }
        stopTyping(in: chat)
    }

    private func stopTyping(in chat: ChatID) {
        typingTimeouts.removeValue(forKey: chat)?.cancel()
        eventContinuation.yield(.typing(chat: chat, isTyping: false))
    }
}
