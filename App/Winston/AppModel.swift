import Foundation
import OSLog
import PhotosUI
import SwiftUI
import TelegramLink
import VoiceLoop
#if os(iOS)
import UIKit
#endif

/// `@AppStorage` keys, shared by the views that read and write them.
enum StorageKey {
    static let selectedChatID = "selectedChatID"
    static let pauseThreshold = "pauseThreshold"
    static let voiceIdentifier = "voiceIdentifier"
}

private let logger = Logger(subsystem: "com.milestonemade.winston", category: "AppModel")

/// Owns all app state: the Telegram session, the bot chats and their messages, and the voice loop.
@Observable
final class AppModel {
    /// False when `Secrets.xcconfig` is missing, so there is no Telegram session.
    let hasCredentials: Bool
    let voiceLoop: VoiceLoop

    private(set) var authState: AuthState = .starting
    /// Why TDLib failed to start, if it did.
    private(set) var startError: String?

    private(set) var chats: [BotChat] = []
    private(set) var chatsLoaded = false
    private(set) var chatsError: String?
    /// The chat the user picked. The chat screen persists it; `currentChat` falls back to the first chat.
    var selectedChatID: ChatID?
    private(set) var messages: [ChatID: [ChatMessage]] = [:]
    private(set) var typingChats: Set<ChatID> = []
    private(set) var downloadedFiles: [Int32: URL] = [:]
    private(set) var downloadingFiles: Set<Int32> = []
    private(set) var isSendingPhoto = false

    private(set) var isVoiceMode = false
    /// A user-facing error from the last action. The chat screen shows it in an alert.
    var errorMessage: String?

    /// Nil without credentials, and in previews. One instance for the app's lifetime: once started it must
    /// never be deallocated, because TDLib's client manager blocks while tearing down.
    private let link: TelegramLink?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var isLoadingChats = false

    init() {
        voiceLoop = VoiceLoop()
        if let secrets = AppSecrets.load() {
            link = TelegramLink(config: Self.telegramConfig(secrets))
            hasCredentials = true
        } else {
            link = nil
            hasCredentials = false
        }
    }

    #if DEBUG
    /// A model with sample data and no Telegram session, for SwiftUI previews.
    init(previewChats: [BotChat], messages: [ChatID: [ChatMessage]], authState: AuthState) {
        voiceLoop = VoiceLoop()
        link = nil
        hasCredentials = true
        self.authState = authState
        chats = previewChats
        chatsLoaded = true
        self.messages = messages
    }
    #endif

    private static func telegramConfig(_ secrets: AppSecrets) -> TelegramConfig {
        let directory = URL.applicationSupportDirectory.appending(path: "Telegram", directoryHint: .isDirectory)
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        #if os(iOS)
        let deviceModel = UIDevice.current.model
        let systemVersion = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #else
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let deviceModel = "Mac"
        let systemVersion = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #endif
        return TelegramConfig(
            apiID: secrets.apiID,
            apiHash: secrets.apiHash,
            databaseDirectory: directory.appending(path: "db", directoryHint: .isDirectory),
            filesDirectory: directory.appending(path: "files", directoryHint: .isDirectory),
            deviceModel: deviceModel,
            systemVersion: systemVersion,
            applicationVersion: "\(version) (\(build))"
        )
    }

    // MARK: - Startup

    /// Starts consuming the Telegram and voice streams, then starts TDLib. Only the first call does anything:
    /// `TelegramLink.start()` runs once per instance, and TelegramLink restarts itself after a logout.
    func start() {
        guard let link, !started else { return }
        started = true
        Task {
            for await state in link.authStates {
                handle(state)
            }
        }
        Task {
            for await event in link.events {
                handle(event)
            }
        }
        Task {
            for await utterance in voiceLoop.utterances {
                await sendText(utterance.messageText)
            }
        }
        Task {
            do {
                try await link.start()
            } catch {
                startError = userMessage(for: error)
            }
        }
    }

    // MARK: - Login

    func submitPhoneNumber(_ phoneNumber: String) async throws {
        try await link?.submitPhoneNumber(phoneNumber)
    }

    func submitCode(_ code: String) async throws {
        try await link?.submitCode(code)
    }

    func submitPassword(_ password: String) async throws {
        try await link?.submitPassword(password)
    }

    func logOut() async {
        do {
            try await link?.logOut()
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    private func handle(_ state: AuthState) {
        authState = state
        switch state {
        case .ready:
            Task { await loadChats() }
        case .loggingOut, .closed:
            clearSession()
        default:
            break
        }
    }

    private func clearSession() {
        if isVoiceMode {
            voiceLoop.stop()
            isVoiceMode = false
        }
        chats = []
        chatsLoaded = false
        chatsError = nil
        messages = [:]
        typingChats = []
        downloadedFiles = [:]
    }

    // MARK: - Chats

    /// The selected chat, or the first bot chat when nothing valid is selected.
    var currentChat: BotChat? {
        chats.first { $0.id == selectedChatID } ?? chats.first
    }

    var currentMessages: [ChatMessage] {
        currentChat.flatMap { messages[$0.id] } ?? []
    }

    var isBotTyping: Bool {
        currentChat.map { typingChats.contains($0.id) } ?? false
    }

    /// The bot's latest message in the current chat, which the 👍 button reacts to.
    var latestIncomingMessage: ChatMessage? {
        currentMessages.last { !$0.isOutgoing }
    }

    /// Loads the bot chats and their recent history.
    func loadChats() async {
        guard let link, !isLoadingChats else { return }
        isLoadingChats = true
        defer { isLoadingChats = false }
        chatsError = nil
        do {
            // botChats() lists every bot chat by recency. Drop @BotFather and sort by title so the picker is stable.
            chats = try await link.botChats()
                .filter { $0.username?.lowercased() != "botfather" }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            chatsLoaded = true
        } catch {
            chatsError = userMessage(for: error)
            return
        }
        for chat in chats {
            do {
                let history = try await link.history(in: chat.id, limit: 50)
                // Keep anything that arrived as an event while the history was loading.
                let historyIDs = Set(history.map(\.id))
                let newer = (messages[chat.id] ?? []).filter { !historyIDs.contains($0.id) }
                messages[chat.id] = history + newer
            } catch {
                errorMessage = "Couldn't load the history for \(chat.title): \(userMessage(for: error))"
            }
        }
    }

    private func isBotChat(_ chat: ChatID) -> Bool {
        chats.contains { $0.id == chat }
    }

    private func handle(_ event: ChatEvent) {
        switch event {
        case .newMessage(let message):
            guard isBotChat(message.chatID) else { return }
            let isNew = upsert(message, replacing: message.id)
            if !message.isOutgoing {
                typingChats.remove(message.chatID)
                if isNew, isVoiceMode, message.chatID == currentChat?.id {
                    speak(message)
                }
            }
        case .reactionsChanged(let chat, let id, let reactions):
            updateMessage(id, in: chat) { $0.reactions = reactions }
        case .typing(let chat, let isTyping):
            guard isBotChat(chat) else { return }
            if isTyping {
                typingChats.insert(chat)
            } else {
                typingChats.remove(chat)
            }
        case .sendSucceeded(let chat, let oldID, let message):
            guard isBotChat(chat) else { return }
            upsert(message, replacing: oldID)
        case .sendFailed(let chat, let id, let error):
            updateMessage(id, in: chat) { $0.sendState = .failed(error) }
        }
    }

    /// Replaces the message with ID `oldID`, or appends `message` if there is none. Returns true when appended.
    @discardableResult
    private func upsert(_ message: ChatMessage, replacing oldID: MessageID) -> Bool {
        var list = messages[message.chatID] ?? []
        let isNew: Bool
        if let index = list.firstIndex(where: { $0.id == oldID }) {
            list[index] = message
            isNew = false
        } else {
            list.append(message)
            isNew = true
        }
        messages[message.chatID] = list
        return isNew
    }

    private func updateMessage(_ id: MessageID, in chat: ChatID, _ change: (inout ChatMessage) -> Void) {
        guard var list = messages[chat], let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index])
        messages[chat] = list
    }

    // MARK: - Sending

    /// Sends `text` exactly as given to the current chat. Returns false and sets `errorMessage` on failure.
    @discardableResult
    func sendText(_ text: String) async -> Bool {
        guard let link, let chat = currentChat else { return false }
        do {
            try await link.sendText(text, to: chat.id)
            return true
        } catch {
            errorMessage = userMessage(for: error)
            return false
        }
    }

    /// Sends a picked photo, downscaled and re-encoded as JPEG, with an optional caption.
    /// Returns false and sets `errorMessage` on failure.
    func sendPhoto(_ item: PhotosPickerItem, caption: String) async -> Bool {
        guard let link, let chat = currentChat else { return false }
        isSendingPhoto = true
        defer { isSendingPhoto = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw PhotoFiles.Failure.unreadableImage
            }
            // TDLib uploads after sendPhoto returns, and the sent message's photo can keep pointing at this
            // file, so it stays in the temporary directory for the system to clean up.
            let fileURL = try await PhotoFiles.jpegForSending(from: data)
            try await link.sendPhoto(fileURL: fileURL, caption: caption.isEmpty ? nil : caption, to: chat.id)
            return true
        } catch {
            errorMessage = userMessage(for: error)
            return false
        }
    }

    func toggleThumbsUp(on message: ChatMessage) async {
        guard let link else { return }
        do {
            try await link.toggleReaction("👍", on: message.id, in: message.chatID)
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    /// Marks an incoming message read so Adam's other Telegram apps don't show it as unread.
    func markRead(_ message: ChatMessage) {
        guard let link, !message.isOutgoing else { return }
        Task {
            do {
                try await link.markRead([message.id], in: message.chatID)
            } catch {
                logger.error("markRead failed: \(String(describing: error))")
            }
        }
    }

    // MARK: - Files

    /// The local URL of a file, if it's already downloaded.
    func localURL(for file: FileRef) -> URL? {
        downloadedFiles[file.id] ?? file.localPath.map { URL(filePath: $0) }
    }

    func isDownloading(_ file: FileRef) -> Bool {
        downloadingFiles.contains(file.id)
    }

    /// Downloads a file if needed and caches its local URL.
    func download(_ file: FileRef) async throws -> URL {
        if let url = localURL(for: file) { return url }
        guard let link else { throw TelegramLinkError.notStarted }
        downloadingFiles.insert(file.id)
        defer { downloadingFiles.remove(file.id) }
        let url = try await link.downloadFile(file)
        downloadedFiles[file.id] = url
        return url
    }

    // MARK: - Voice

    /// Switches between text and voice mode. Starting voice mode can fail, for example without mic permission.
    func setVoiceMode(_ on: Bool) async {
        if on {
            guard !isVoiceMode else { return }
            isVoiceMode = true
            do {
                try await voiceLoop.start()
                // Voice mode may have been turned off while start() waited for permission.
                if !isVoiceMode { voiceLoop.stop() }
            } catch {
                isVoiceMode = false
                errorMessage = userMessage(for: error)
            }
        } else {
            voiceLoop.stop()
            isVoiceMode = false
        }
    }

    private func speak(_ message: ChatMessage) {
        let label: String? = switch message.attachment {
        case nil: nil
        case .photo: "Photo"
        case .document(_, let fileName, _, _): "File: \(fileName)"
        }
        let text = [label, message.text]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
        guard !text.isEmpty else { return }
        voiceLoop.speak(text)
    }
}

/// A short, plain description of an error for the UI.
func userMessage(for error: any Error) -> String {
    if let error = error as? TelegramLinkError {
        switch error {
        case .tdlib(_, let message): return message
        case .notStarted: return "Telegram hasn't started yet."
        case .notImplemented: return "Telegram support isn't implemented yet."
        }
    }
    if let error = error as? VoiceLoopError {
        switch error {
        case .microphonePermissionDenied:
            return "Winston can't use the microphone. Turn on microphone access for Winston in Privacy & Security settings."
        case .speechPermissionDenied:
            return "Winston can't use speech recognition. Turn on speech recognition for Winston in Privacy & Security settings."
        case .speechModelUnavailable:
            return "The on-device speech model for your language isn't available."
        case .notImplemented:
            return "Voice mode isn't implemented yet."
        }
    }
    if let error = error as? PhotoFiles.Failure {
        switch error {
        case .unreadableImage: return "Winston couldn't read that photo."
        case .encodingFailed: return "Winston couldn't convert that photo to JPEG."
        }
    }
    return error.localizedDescription
}
