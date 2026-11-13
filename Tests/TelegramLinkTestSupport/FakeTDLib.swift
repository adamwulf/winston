import Foundation
@preconcurrency import TDLibKit
import TelegramLink

/// Stands in for TDLib behind `TelegramLink`.
///
/// It keeps a pretend account (bot chats, their messages, files), answers the link's requests
/// from it, records each request, and walks TDLib's login states. Updates go to the link as
/// the JSON TDLib sends, so the link's decoding and mapping run for real.
package final class FakeTDLib: TDLibClientSource, TDLibRequests, @unchecked Sendable {

    /// A request the link made, with the arguments the tests check.
    package enum Request: Equatable, Sendable {
        /// A synchronous `execute`, by TDLib function name, such as `setLogVerbosityLevel`.
        case execute(String)
        case setTdlibParameters(apiID: Int?, apiHash: String?, databaseDirectory: String?, filesDirectory: String?)
        case setAuthenticationPhoneNumber(String?)
        case checkAuthenticationCode(String?)
        case checkAuthenticationPassword(String?)
        case logOut
        case loadChats(limit: Int?)
        case getChats(limit: Int?)
        case getChat(Int64?)
        case getUser(Int64?)
        case getChatHistory(chatID: Int64?, fromMessageID: Int64?, limit: Int?)
        case getMessage(chatID: Int64?, messageID: Int64?)
        case sendText(chatID: Int64?, text: String)
        case sendPhoto(chatID: Int64?, path: String, caption: String?, width: Int, height: Int)
        case addReaction(chatID: Int64?, messageID: Int64?, emoji: String)
        case removeReaction(chatID: Int64?, messageID: Int64?, emoji: String)
        case viewMessages(chatID: Int64?, messageIDs: [Int64]?, forceRead: Bool?)
        case downloadFile(fileID: Int?)
    }

    /// The kinds of request, for `fail(_:code:message:)`.
    package enum Call: Hashable, Sendable {
        case execute, setTdlibParameters, setAuthenticationPhoneNumber, checkAuthenticationCode
        case checkAuthenticationPassword, logOut, loadChats, getChats, getChat, getUser, getChatHistory
        case getMessage, sendMessage, addMessageReaction, removeMessageReaction, viewMessages, downloadFile
    }

    private struct State {
        var updateHandlers: [@Sendable (Data) -> Void] = []
        var requests: [Request] = []
        var failures: [Call: any Swift.Error] = [:]
        /// Chats whose history can't be read, and the error `getChatHistory` gives for each.
        var historyFailures: [Int64: any Swift.Error] = [:]
        var isLoggedIn: Bool
        var passwordHint: String?
        var chats: [Chat] = []
        var users: [Int64: User] = [:]
        /// Each chat's messages, in the order they were added.
        var messages: [Int64: [Message]] = [:]
        var files: [Int: File] = [:]
        var historyPageSize = 100
        var nextTemporaryID: Int64 = 9_000_000
        /// Calls the tests are holding back, and the requests waiting on them.
        var held: Set<Call> = []
        var waiting: [Call: [CheckedContinuation<Void, Never>]] = [:]
        var closeCount = 0
    }

    package let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()
    private var state: State

    /// - Parameters:
    ///   - isLoggedIn: whether the account already has a session, so TDLib goes straight to ready.
    ///   - passwordHint: set when the account has a two-step verification password.
    package init(isLoggedIn: Bool = true, passwordHint: String? = nil) {
        state = State(isLoggedIn: isLoggedIn, passwordHint: passwordHint)
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    private func withState<T>(_ body: (inout State) throws -> T) rethrows -> T {
        try lock.withLock { try body(&state) }
    }

    // MARK: - What the tests set up and read

    /// Every request so far, in order.
    package var requests: [Request] {
        withState { $0.requests }
    }

    /// How many clients the link has created. A second one follows a logout.
    package var clientCount: Int {
        withState { $0.updateHandlers.count }
    }

    /// Makes every later `call` fail with a TDLib error, until `succeed(_:)`.
    package func fail(_ call: Call, code: Int, message: String) {
        fail(call, with: TDLibKit.Error(code: code, message: message))
    }

    /// Makes every later `call` fail with `error`, until `succeed(_:)`.
    package func fail(_ call: Call, with error: any Swift.Error) {
        withState { $0.failures[call] = error }
    }

    package func succeed(_ call: Call) {
        withState { $0.failures[call] = nil }
    }

    /// Makes every later `getChatHistory` of one chat fail with a TDLib error, as when that
    /// chat can't be read. The other chats' histories still load.
    package func failHistory(of chatID: Int64, code: Int, message: String) {
        withState { $0.historyFailures[chatID] = TDLibKit.Error(code: code, message: message) }
    }

    /// Makes every later `call` wait, after it is recorded in `requests`, until `release(_:)`.
    /// For tests of what happens while a request is in flight.
    package func hold(_ call: Call) {
        withState { _ = $0.held.insert(call) }
    }

    /// Lets the held `call` requests carry on, and stops holding new ones.
    package func release(_ call: Call) {
        let waiting = withState { state in
            state.held.remove(call)
            return state.waiting.removeValue(forKey: call) ?? []
        }
        for continuation in waiting {
            continuation.resume()
        }
    }

    /// How many times the link has closed its clients, as it does before the app quits.
    package var closeCount: Int {
        withState { $0.closeCount }
    }

    /// Adds a chat to the main chat list, and the user it is with.
    package func add(chat: Chat, user: User? = nil) {
        withState { state in
            state.chats.append(chat)
            if let user {
                state.users[user.id] = user
            }
        }
    }

    /// Adds a private chat with a bot.
    package func addBotChat(id: Int64, title: String, username: String) {
        let bot = botChat(id: id, title: title, username: username)
        add(chat: bot.chat, user: bot.user)
    }

    /// Puts messages in a chat's history without telling the link, as if they were already there.
    package func addHistory(_ messages: [Message]) {
        withState { state in
            for message in messages {
                state.messages[message.chatId, default: []].append(message)
            }
        }
    }

    /// The most messages one `getChatHistory` returns. TDLib often returns only a few.
    package var historyPageSize: Int {
        get { withState { $0.historyPageSize } }
        set { withState { $0.historyPageSize = newValue } }
    }

    /// What `downloadFile` returns for the file's ID.
    package func setFile(_ file: File) {
        withState { $0.files[file.id] = file }
    }

    /// The message as the account holds it now, with any reactions added since.
    package func message(_ id: Int64, in chatID: Int64) -> Message? {
        withState { $0.messages[chatID]?.first { $0.id == id } }
    }

    // MARK: - Updates

    /// Sends an update to the newest client, as TDLib's JSON.
    package func send(_ update: Update) {
        do {
            sendRaw(try encoder.encode(update))
        } catch {
            preconditionFailure("couldn't encode \(update): \(error)")
        }
    }

    /// Sends raw JSON to the newest client, for updates TDLibKit has no type for.
    package func sendRaw(_ json: Data) {
        let handler = withState { $0.updateHandlers.last }
        handler?(json)
    }

    private func send(_ authorizationState: AuthorizationState) {
        send(.updateAuthorizationState(UpdateAuthorizationState(authorizationState: authorizationState)))
    }

    /// A message arrives in a chat: it joins the history and the link is told.
    package func receive(_ message: Message) {
        addHistory([message])
        send(.updateNewMessage(UpdateNewMessage(message: message)))
    }

    /// The bot starts typing, or with `false` stops.
    package func setTyping(_ isTyping: Bool, in chatID: Int64) {
        send(.updateChatAction(UpdateChatAction(
            action: isTyping ? .chatActionTyping : .chatActionCancel,
            chatId: chatID,
            senderId: .messageSenderUser(MessageSenderUser(userId: chatID)),
            topicId: nil
        )))
    }

    /// The server accepts a pending message, which gets its final ID. Returns the sent message.
    @discardableResult
    package func confirmSend(of temporaryID: Int64, in chatID: Int64, as finalID: Int64) -> Message? {
        let sent: Message? = withState { state in
            guard let index = state.messages[chatID]?.firstIndex(where: { $0.id == temporaryID }) else { return nil }
            let sent = patched(state.messages[chatID]![index]) { json in
                json["id"] = finalID
                json["sending_state"] = nil
            }
            state.messages[chatID]![index] = sent
            return sent
        }
        if let sent {
            send(.updateMessageSendSucceeded(UpdateMessageSendSucceeded(message: sent, oldMessageId: temporaryID)))
        }
        return sent
    }

    /// The server rejects a pending message.
    package func failSend(of temporaryID: Int64, in chatID: Int64, code: Int = 400, message: String) {
        guard let pending = self.message(temporaryID, in: chatID) else { return }
        send(.updateMessageSendFailed(UpdateMessageSendFailed(
            error: TDLibKit.Error(code: code, message: message),
            message: pending,
            oldMessageId: temporaryID
        )))
    }

    // MARK: - TDLibClientSource

    package func makeClient(updateHandler: @escaping @Sendable (Data) -> Void) -> any TDLibRequests {
        withState { $0.updateHandlers.append(updateHandler) }
        // TDLib's first update to a new client.
        send(.authorizationStateWaitTdlibParameters)
        return self
    }

    package func closeClients() {
        withState { $0.closeCount += 1 }
        send(.authorizationStateClosing)
        send(.authorizationStateClosed)
    }

    // MARK: - TDLibRequests

    /// Records the request, and throws if the tests made that call fail.
    private func record(_ request: Request, _ call: Call) throws {
        let failure = withState { state in
            state.requests.append(request)
            return state.failures[call]
        }
        if let failure {
            throw failure
        }
    }

    /// `record` for the asynchronous requests: after recording, waits while the tests hold
    /// that call, then throws if they made it fail.
    private func begin(_ request: Request, _ call: Call) async throws {
        withState { $0.requests.append(request) }
        await withCheckedContinuation { continuation in
            let isHeld = withState { state in
                guard state.held.contains(call) else { return false }
                state.waiting[call, default: []].append(continuation)
                return true
            }
            if !isHeld {
                continuation.resume()
            }
        }
        if let failure = withState({ $0.failures[call] }) {
            throw failure
        }
    }

    package func execute(query: TdQuery) throws -> [String: Any]? {
        let json = try JSONSerialization.jsonObject(with: query.make(with: nil)) as? [String: Any]
        try record(.execute(json?["@type"] as? String ?? ""), .execute)
        return ["@type": "ok"]
    }

    package func setTdlibParameters(
        apiHash: String?,
        apiId: Int?,
        applicationVersion: String?,
        databaseDirectory: String?,
        databaseEncryptionKey: Data?,
        deviceModel: String?,
        filesDirectory: String?,
        systemLanguageCode: String?,
        systemVersion: String?,
        useChatInfoDatabase: Bool?,
        useFileDatabase: Bool?,
        useMessageDatabase: Bool?,
        useSecretChats: Bool?,
        useTestDc: Bool?
    ) async throws -> Ok {
        try await begin(
            .setTdlibParameters(
                apiID: apiId,
                apiHash: apiHash,
                databaseDirectory: databaseDirectory,
                filesDirectory: filesDirectory
            ),
            .setTdlibParameters
        )
        send(withState { $0.isLoggedIn } ? .authorizationStateReady : .authorizationStateWaitPhoneNumber)
        return Ok()
    }

    package func setAuthenticationPhoneNumber(
        phoneNumber: String?,
        settings: PhoneNumberAuthenticationSettings?
    ) async throws -> Ok {
        try await begin(.setAuthenticationPhoneNumber(phoneNumber), .setAuthenticationPhoneNumber)
        send(.authorizationStateWaitCode(AuthorizationStateWaitCode(codeInfo: AuthenticationCodeInfo(
            nextType: nil,
            phoneNumber: phoneNumber ?? "",
            timeout: 0,
            type: .authenticationCodeTypeTelegramMessage(AuthenticationCodeTypeTelegramMessage(length: 5))
        ))))
        return Ok()
    }

    package func checkAuthenticationCode(code: String?) async throws -> Ok {
        try await begin(.checkAuthenticationCode(code), .checkAuthenticationCode)
        if let hint = withState({ $0.passwordHint }) {
            send(.authorizationStateWaitPassword(AuthorizationStateWaitPassword(
                hasPassportData: false,
                hasRecoveryEmailAddress: false,
                passwordHint: hint,
                recoveryEmailAddressPattern: ""
            )))
        } else {
            withState { $0.isLoggedIn = true }
            send(.authorizationStateReady)
        }
        return Ok()
    }

    package func checkAuthenticationPassword(password: String?) async throws -> Ok {
        try await begin(.checkAuthenticationPassword(password), .checkAuthenticationPassword)
        withState { $0.isLoggedIn = true }
        send(.authorizationStateReady)
        return Ok()
    }

    package func logOut() async throws -> Ok {
        try await begin(.logOut, .logOut)
        withState { $0.isLoggedIn = false }
        send(.authorizationStateLoggingOut)
        send(.authorizationStateClosed)
        return Ok()
    }

    package func loadChats(chatList: ChatList?, limit: Int?) async throws -> Ok {
        try await begin(.loadChats(limit: limit), .loadChats)
        return Ok()
    }

    package func getChats(chatList: ChatList?, limit: Int?) async throws -> Chats {
        try await begin(.getChats(limit: limit), .getChats)
        let ids = withState { $0.chats.map(\.id) }
        return Chats(chatIds: ids, totalCount: ids.count)
    }

    package func getChat(chatId: Int64?) async throws -> Chat {
        try await begin(.getChat(chatId), .getChat)
        guard let chat = withState({ $0.chats.first { $0.id == chatId } }) else {
            throw TDLibKit.Error(code: 400, message: "Chat not found")
        }
        return chat
    }

    package func getUser(userId: Int64?) async throws -> User {
        try await begin(.getUser(userId), .getUser)
        guard let userId, let user = withState({ $0.users[userId] }) else {
            throw TDLibKit.Error(code: 400, message: "User not found")
        }
        return user
    }

    /// Like TDLib with `offset: 0`: newest first, starting at the newest message for 0, and
    /// otherwise at the message just older than `fromMessageId`. TDLib leaves `fromMessageId`
    /// itself out unless the offset is negative (`OrderedMessages::get_history` steps past it).
    package func getChatHistory(
        chatId: Int64?,
        fromMessageId: Int64?,
        limit: Int?,
        offset: Int?,
        onlyLocal: Bool?
    ) async throws -> Messages {
        try await begin(.getChatHistory(chatID: chatId, fromMessageID: fromMessageId, limit: limit), .getChatHistory)
        if let failure = withState({ $0.historyFailures[chatId ?? 0] }) {
            throw failure
        }
        let page: [Message] = withState { state in
            let newestFirst = (state.messages[chatId ?? 0] ?? []).sorted { $0.id > $1.id }
            let from = fromMessageId ?? 0
            let eligible = from == 0 ? newestFirst : newestFirst.filter { $0.id < from }
            return Array(eligible.prefix(min(limit ?? 100, state.historyPageSize)))
        }
        return Messages(messages: page, totalCount: page.count)
    }

    package func getMessage(chatId: Int64?, messageId: Int64?) async throws -> Message {
        try await begin(.getMessage(chatID: chatId, messageID: messageId), .getMessage)
        guard let chatId, let messageId, let message = message(messageId, in: chatId) else {
            throw TDLibKit.Error(code: 404, message: "Not Found")
        }
        return message
    }

    /// Like TDLib, the message starts out pending under a temporary ID, and the link hears of
    /// it as a new message. `confirmSend` or `failSend` settles it.
    package func sendMessage(
        chatId: Int64?,
        inputMessageContent: InputMessageContent?,
        options: MessageSendOptions?,
        replyMarkup: ReplyMarkup?,
        replyTo: InputMessageReplyTo?,
        topicId: MessageTopic?
    ) async throws -> Message {
        let content: MessageContent
        switch inputMessageContent {
        case .inputMessageText(let text):
            try await begin(.sendText(chatID: chatId, text: text.text.text), .sendMessage)
            content = .messageText(MessageText(linkPreview: nil, linkPreviewOptions: nil, text: text.text))
        case .inputMessagePhoto(let photo):
            var path = ""
            if case .inputFileLocal(let local) = photo.photo.photo {
                path = local.path
            }
            try await begin(
                .sendPhoto(
                    chatID: chatId,
                    path: path,
                    caption: photo.caption?.text,
                    width: photo.photo.width,
                    height: photo.photo.height
                ),
                .sendMessage
            )
            content = .messagePhoto(MessagePhoto(
                caption: photo.caption ?? formatted(""),
                hasSpoiler: false,
                isSecret: false,
                photo: Photo(
                    hasStickers: false,
                    minithumbnail: nil,
                    sizes: [photoSize(
                        fileID: 1,
                        width: photo.photo.width,
                        height: photo.photo.height,
                        downloadedPath: path
                    )]
                ),
                showCaptionAboveMedia: false,
                video: nil
            ))
        default:
            preconditionFailure("TelegramLink only sends text and photos")
        }
        let pending: Message = withState { state in
            state.nextTemporaryID += 1
            let pending = makeMessage(
                id: state.nextTemporaryID,
                chatID: chatId ?? 0,
                isOutgoing: true,
                content: content,
                sendingState: .messageSendingStatePending(MessageSendingStatePending(sendingId: 0))
            )
            state.messages[pending.chatId, default: []].append(pending)
            return pending
        }
        send(.updateNewMessage(UpdateNewMessage(message: pending)))
        return pending
    }

    package func addMessageReaction(
        chatId: Int64?,
        isBig: Bool?,
        messageId: Int64?,
        reactionType: ReactionType?,
        updateRecentReactions: Bool?
    ) async throws -> Ok {
        let emoji = Self.emoji(of: reactionType)
        try await begin(.addReaction(chatID: chatId, messageID: messageId, emoji: emoji), .addMessageReaction)
        try react(chatID: chatId, messageID: messageId) { reactions in
            if let index = reactions.firstIndex(where: { Self.emoji(of: $0.type) == emoji }) {
                reactions[index] = messageReaction(
                    reactions[index].type,
                    count: reactions[index].totalCount + 1,
                    isChosen: true
                )
            } else if let reactionType {
                reactions.append(messageReaction(reactionType, count: 1, isChosen: true))
            }
        }
        return Ok()
    }

    package func removeMessageReaction(
        chatId: Int64?,
        messageId: Int64?,
        reactionType: ReactionType?
    ) async throws -> Ok {
        let emoji = Self.emoji(of: reactionType)
        try await begin(.removeReaction(chatID: chatId, messageID: messageId, emoji: emoji), .removeMessageReaction)
        try react(chatID: chatId, messageID: messageId) { reactions in
            guard let index = reactions.firstIndex(where: { Self.emoji(of: $0.type) == emoji }) else { return }
            if reactions[index].totalCount > 1 {
                reactions[index] = messageReaction(
                    reactions[index].type,
                    count: reactions[index].totalCount - 1,
                    isChosen: false
                )
            } else {
                reactions.remove(at: index)
            }
        }
        return Ok()
    }

    package func viewMessages(
        chatId: Int64?,
        forceRead: Bool?,
        messageIds: [Int64]?,
        source: MessageSource?
    ) async throws -> Ok {
        try await begin(.viewMessages(chatID: chatId, messageIDs: messageIds, forceRead: forceRead), .viewMessages)
        return Ok()
    }

    package func downloadFile(
        fileId: Int?,
        limit: Int64?,
        offset: Int64?,
        priority: Int?,
        synchronous: Bool?
    ) async throws -> File {
        try await begin(.downloadFile(fileID: fileId), .downloadFile)
        guard let fileId, let file = withState({ $0.files[fileId] }) else {
            throw TDLibKit.Error(code: 400, message: "Invalid file identifier")
        }
        return file
    }

    // MARK: - Helpers

    private static func emoji(of type: ReactionType?) -> String {
        if case .reactionTypeEmoji(let emoji) = type {
            return emoji.emoji
        }
        return ""
    }

    /// Changes a stored message's reactions and tells the link, as TDLib does.
    private func react(chatID: Int64?, messageID: Int64?, _ change: (inout [MessageReaction]) -> Void) throws {
        let info: MessageInteractionInfo? = withState { state in
            guard let chatID, let index = state.messages[chatID]?.firstIndex(where: { $0.id == messageID }) else {
                return nil
            }
            var reactions = state.messages[chatID]![index].interactionInfo?.reactions?.reactions ?? []
            change(&reactions)
            let info = interactionInfo(reactions)
            state.messages[chatID]![index] = patched(state.messages[chatID]![index]) { json in
                json["interaction_info"] = jsonObject(info)
            }
            return info
        }
        guard let chatID, let messageID, let info else {
            throw TDLibKit.Error(code: 404, message: "Not Found")
        }
        send(.updateMessageInteractionInfo(UpdateMessageInteractionInfo(
            chatId: chatID,
            interactionInfo: info,
            messageId: messageID
        )))
    }

    /// A copy of `message` with fields of its TDLib JSON changed. TDLibKit's messages are
    /// immutable, with dozens of fields.
    private func patched(_ message: Message, _ change: (inout [String: Any]) -> Void) -> Message {
        do {
            guard var json = jsonObject(message) as? [String: Any] else {
                preconditionFailure("a message encodes as a JSON object")
            }
            change(&json)
            return try decoder.decode(Message.self, from: JSONSerialization.data(withJSONObject: json))
        } catch {
            preconditionFailure("couldn't patch the message: \(error)")
        }
    }

    private func jsonObject(_ value: some Encodable) -> Any {
        do {
            return try JSONSerialization.jsonObject(with: encoder.encode(value))
        } catch {
            preconditionFailure("couldn't encode \(value): \(error)")
        }
    }
}

extension FakeTDLib {
    /// A link that talks to this fake in place of TDLib. `typingTimeout` is how long "typing"
    /// lasts without a refresh; the app's is 6 seconds.
    package func makeLink(
        config: TelegramConfig = .testing,
        typingTimeout: Duration = .seconds(60)
    ) -> TelegramLink {
        TelegramLink(config: config, typingTimeout: typingTimeout) { self }
    }
}

extension TelegramConfig {
    /// Made-up credentials and folders. The fake never touches the disk.
    package static var testing: TelegramConfig {
        TelegramConfig(
            apiID: 42,
            apiHash: "hash",
            databaseDirectory: URL(filePath: "/tmp/winston-tests/db", directoryHint: .isDirectory),
            filesDirectory: URL(filePath: "/tmp/winston-tests/files", directoryHint: .isDirectory),
            deviceModel: "Test",
            systemVersion: "1.0",
            applicationVersion: "1 (1)",
            systemLanguageCode: "en"
        )
    }
}
