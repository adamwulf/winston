import Foundation
import Logging
import LogSupport
import Observation
import TelegramLink
import VoiceLoop
#if os(iOS)
import UIKit
#endif

/// UserDefaults keys for the settings AppModel persists.
private enum StorageKey {
    static let selectedChatID = "selectedChatID"
    static let pauseThreshold = "pauseThreshold"
    static let voiceIdentifier = "voiceIdentifier"
    static let speechRate = "speechRate"
    static let speechPitch = "speechPitch"
    static let pausesOtherAudio = "pausesOtherAudio"
}

/// Owns all app state: the Telegram session, the bot chats and their messages, and the voice loop.
@MainActor
@Observable
public final class AppModel {
    private static let log = Logger(label: "app.model")

    /// False when `Secrets.xcconfig` is missing, so there is no Telegram session.
    public let hasCredentials: Bool
    public let voiceLoop: VoiceLoop

    public private(set) var authState: AuthState = .starting
    /// Why TDLib failed to start, if it did.
    public private(set) var startError: String?

    public private(set) var chats: [BotChat] = []
    public private(set) var chatsLoaded = false
    public private(set) var chatsError: String?
    /// The bot chat shown in the chat screen. Persisted; reset to the first chat if it's no longer a bot chat.
    public var selectedChatID: ChatID? {
        didSet { defaults.set(selectedChatID?.rawValue, forKey: StorageKey.selectedChatID) }
    }
    public private(set) var messages: [ChatID: [ChatMessage]] = [:]
    public private(set) var typingChats: Set<ChatID> = []
    public private(set) var downloadedFiles: [Int32: URL] = [:]
    public private(set) var downloadingFiles: Set<Int32> = []
    public private(set) var isSendingPhoto = false

    public private(set) var isVoiceMode = false
    /// True while `voiceLoop.start()` runs (permission prompts, model download). The loop stays `.off` until then.
    public private(set) var isStartingVoice = false
    /// Counts the times voice mode was turned off, so `setVoiceMode(_:)` can tell when a quick off-and-on
    /// cancelled the start it is waiting on.
    @ObservationIgnored private var voiceModeOffCount = 0
    /// Seconds the transcript must stay unchanged before voice mode sends it. Persisted.
    public var pauseThreshold: Double {
        didSet {
            defaults.set(pauseThreshold, forKey: StorageKey.pauseThreshold)
            applyVoiceSettings()
        }
    }
    /// The `VoiceOption.id` to speak with, or nil for VoiceLoop's default. Persisted.
    public var voiceIdentifier: String? {
        didSet {
            defaults.set(voiceIdentifier, forKey: StorageKey.voiceIdentifier)
            applyVoiceSettings()
        }
    }
    /// How fast replies are spoken, as a `VoiceLoop.speechRate`. Persisted.
    public var speechRate: Float {
        didSet {
            defaults.set(speechRate, forKey: StorageKey.speechRate)
            applyVoiceSettings()
        }
    }
    /// How high replies are spoken, as a `VoiceLoop.speechPitch` multiplier (1 is normal). Persisted.
    public var speechPitch: Float {
        didSet {
            defaults.set(speechPitch, forKey: StorageKey.speechPitch)
            applyVoiceSettings()
        }
    }
    /// Whether voice mode may pause or turn down other apps' audio, such as music. Persisted.
    public var pausesOtherAudio: Bool {
        didSet {
            defaults.set(pausesOtherAudio, forKey: StorageKey.pausesOtherAudio)
            applyVoiceSettings()
        }
    }
    /// A user-facing error from the last action. The chat screen shows it in an alert.
    public var errorMessage: String?

    /// Nil without credentials, and in previews. One instance for the app's lifetime: once started it must
    /// never be deallocated, because TDLib's client manager blocks while tearing down.
    private let link: TelegramLink?
    /// Where the settings persist.
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var started = false
    @ObservationIgnored private var isLoadingChats = false

    /// The app's model: a Telegram session if `Secrets.xcconfig` supplied credentials, the real voice loop, and
    /// the standard user defaults.
    public convenience init() {
        self.init(
            link: AppSecrets.load().map { TelegramLink(config: Self.telegramConfig($0)) },
            voiceLoop: VoiceLoop(),
            defaults: .standard
        )
    }

    /// Tests pass a link over a fake TDLib, a voice loop on offline audio, and defaults of their own.
    /// `hasCredentials` defaults to whether there is a link; only previews have one without the other.
    package init(link: TelegramLink?, voiceLoop: VoiceLoop, defaults: UserDefaults, hasCredentials: Bool? = nil) {
        self.link = link
        self.voiceLoop = voiceLoop
        self.defaults = defaults
        self.hasCredentials = hasCredentials ?? (link != nil)
        selectedChatID = (defaults.object(forKey: StorageKey.selectedChatID) as? Int64).map(ChatID.init)
        pauseThreshold = defaults.object(forKey: StorageKey.pauseThreshold) as? Double ?? 1.2
        voiceIdentifier = defaults.string(forKey: StorageKey.voiceIdentifier)
        speechRate = defaults.object(forKey: StorageKey.speechRate) as? Float ?? VoiceLoop.defaultSpeechRate
        speechPitch = defaults.object(forKey: StorageKey.speechPitch) as? Float ?? VoiceLoop.defaultSpeechPitch
        pausesOtherAudio = defaults.object(forKey: StorageKey.pausesOtherAudio) as? Bool ?? true
        applyVoiceSettings()
    }

    #if DEBUG
    /// A model with sample data and no Telegram session, for SwiftUI previews.
    public convenience init(previewChats: [BotChat], messages: [ChatID: [ChatMessage]], authState: AuthState) {
        self.init(link: nil, voiceLoop: VoiceLoop(), defaults: .standard, hasCredentials: true)
        self.authState = authState
        chats = previewChats
        chatsLoaded = true
        self.messages = messages
        selectedChatID = previewChats.first?.id
    }
    #endif

    private func applyVoiceSettings() {
        voiceLoop.pauseThreshold = .seconds(pauseThreshold)
        voiceLoop.voiceIdentifier = voiceIdentifier
        voiceLoop.speechRate = speechRate
        voiceLoop.speechPitch = speechPitch
        voiceLoop.pausesOtherAudio = pausesOtherAudio
    }

    /// Says a sample sentence in the chosen voice, speed and pitch, for the settings voice picker and the
    /// speed and pitch sliders. Says nothing for a Kokoro voice whose model isn't ready yet, rather than
    /// name it in another voice; settings shows the model's download instead. Either way it cuts off the
    /// preview before.
    public func previewVoice() {
        let voices = VoiceLoop.availableVoices()
        let voice = voices.first { $0.id == voiceIdentifier } ?? voices.first
        if voice?.engine == .kokoro, voiceLoop.kokoroModelState != .ready {
            // The preview before would carry on in the voice just replaced.
            voiceLoop.stopPreview()
            return
        }
        let name = voice?.name ?? "default"
        voiceLoop.preview("This is how I sound with the \(name) voice.")
    }

    /// Where TDLib keeps its data, and how the app describes itself to Telegram.
    static func telegramConfig(_ secrets: AppSecrets) -> TelegramConfig {
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
    public func start() {
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
                Self.log.error("Telegram start failed", error.logContext())
                startError = userMessage(for: error)
            }
        }
    }

    /// Closes the Telegram session cleanly before the app quits. See `TelegramLink.closeForTermination()`.
    public func closeForQuit() async {
        voiceLoop.stop()
        await link?.closeForTermination()
    }

    /// The same, for `applicationWillTerminate`, which must finish before it returns. Waits at
    /// most `timeout`. TelegramLink isn't main-actor isolated, so blocking here can't deadlock it.
    public func closeForQuitBlocking(timeout: DispatchTimeInterval = .seconds(3)) {
        voiceLoop.stop()
        guard let link else { return }
        let closed = DispatchSemaphore(value: 0)
        Task.detached {
            await link.closeForTermination()
            closed.signal()
        }
        _ = closed.wait(timeout: .now() + timeout)
    }

    // MARK: - Login

    public func submitPhoneNumber(_ phoneNumber: String) async throws {
        try await link?.submitPhoneNumber(phoneNumber)
    }

    public func submitCode(_ code: String) async throws {
        try await link?.submitCode(code)
    }

    public func submitPassword(_ password: String) async throws {
        try await link?.submitPassword(password)
    }

    public func logOut() async {
        do {
            try await link?.logOut()
        } catch {
            Self.log.error("log out failed", error.logContext())
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

    public var currentChat: BotChat? {
        chats.first { $0.id == selectedChatID }
    }

    public var currentMessages: [ChatMessage] {
        currentChat.flatMap { messages[$0.id] } ?? []
    }

    public var isBotTyping: Bool {
        currentChat.map { typingChats.contains($0.id) } ?? false
    }

    /// The bot's latest message in the current chat, which the 👍 button reacts to.
    public var latestIncomingMessage: ChatMessage? {
        currentMessages.last { !$0.isOutgoing }
    }

    /// Loads the bot chats and their recent history.
    public func loadChats() async {
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
            if currentChat == nil {
                selectedChatID = chats.first?.id
            }
        } catch {
            Self.log.error("loading bot chats failed", error.logContext())
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
                Self.log.error("loading chat history failed", error.logContext(["chatID": chat.id.description]))
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
            var botAddedThumbsUp = false
            updateMessage(id, in: chat) { message in
                let before = message.othersThumbsUpCount
                message.reactions = reactions
                botAddedThumbsUp = message.othersThumbsUpCount > before
            }
            // In voice mode Adam may not be looking, so the bot's 👍 in the chat he's in chimes.
            if botAddedThumbsUp, isVoiceMode, chat == currentChat?.id {
                voiceLoop.play(.reaction)
            }
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
    public func sendText(_ text: String) async -> Bool {
        guard let link, let chat = currentChat else { return false }
        do {
            try await link.sendText(text, to: chat.id)
            return true
        } catch {
            Self.log.error("sending text failed", error.logContext(["chatID": chat.id.description]))
            errorMessage = userMessage(for: error)
            return false
        }
    }

    /// Sends a picked photo, downscaled and re-encoded as JPEG, with an optional caption.
    /// `loadData` loads the picked photo's data; in the app it is `PhotosPickerItem.loadTransferable`, which
    /// returns nil when the photo can't be read. Returns false and sets `errorMessage` on failure.
    public func sendPhoto(caption: String, loadData: () async throws -> Data?) async -> Bool {
        guard let link, let chat = currentChat else { return false }
        isSendingPhoto = true
        defer { isSendingPhoto = false }
        do {
            guard let data = try await loadData() else {
                throw PhotoFiles.Failure.unreadableImage
            }
            // TDLib uploads after sendPhoto returns, and the sent message's photo can keep pointing at this
            // file, so it stays in the temporary directory for the system to clean up.
            let fileURL = try await PhotoFiles.jpegForSending(from: data)
            try await link.sendPhoto(fileURL: fileURL, caption: caption.isEmpty ? nil : caption, to: chat.id)
            return true
        } catch {
            // Codes only: a picked photo's load error can name the file, and a TDLib upload error's
            // message can hold the local path.
            Self.log.error("sending photo failed", error.tdlibLogCodes(["chatID": chat.id.description]))
            errorMessage = userMessage(for: error)
            return false
        }
    }

    public func toggleThumbsUp(on message: ChatMessage) async {
        guard let link else { return }
        do {
            try await link.toggleReaction("👍", on: message.id, in: message.chatID)
        } catch {
            Self.log.error("toggling reaction failed", error.logContext([
                "chatID": message.chatID.description,
                "messageID": message.id.description,
            ]))
            errorMessage = userMessage(for: error)
        }
    }

    /// Marks an incoming message read so Adam's other Telegram apps don't show it as unread.
    public func markRead(_ message: ChatMessage) {
        guard let link, !message.isOutgoing else { return }
        Task {
            do {
                try await link.markRead([message.id], in: message.chatID)
            } catch {
                Self.log.error("marking message read failed", error.logContext([
                    "chatID": message.chatID.description,
                    "messageID": message.id.description,
                ]))
            }
        }
    }

    // MARK: - Files

    /// The local URL of a file, if it's already downloaded.
    public func localURL(for file: FileRef) -> URL? {
        downloadedFiles[file.id] ?? file.localPath.map { URL(filePath: $0) }
    }

    public func isDownloading(_ file: FileRef) -> Bool {
        downloadingFiles.contains(file.id)
    }

    /// Downloads a file if needed and caches its local URL.
    public func download(_ file: FileRef) async throws -> URL {
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
    /// Turning it on again while already in voice mode resumes a loop that turned itself off.
    public func setVoiceMode(_ on: Bool) async {
        if on {
            isVoiceMode = true
            // A running loop needs no start. Toggled back on while the first start() is still running: that
            // one owns the flag, and starts again below if a quick off cancelled it.
            guard voiceLoop.state == .off, !isStartingVoice else { return }
            isStartingVoice = true
            defer { isStartingVoice = false }
            do {
                var offCount: Int
                repeat {
                    offCount = voiceModeOffCount
                    try await voiceLoop.start()
                    // Turning voice mode off stops the loop, which makes a start() in progress give up. If it
                    // was turned back on since, start again.
                } while isVoiceMode && voiceModeOffCount != offCount
                // Voice mode may have been turned off while start() waited for permission.
                if !isVoiceMode { voiceLoop.stop() }
            } catch {
                Self.log.error("starting voice mode failed", error.logContext())
                isVoiceMode = false
                errorMessage = userMessage(for: error)
            }
        } else {
            voiceModeOffCount += 1
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

extension ChatMessage {
    /// Whether Adam's own 👍 is on this message: what `AppModel.toggleThumbsUp(on:)` flips.
    public var hasMyThumbsUp: Bool {
        reactions.contains { $0.emoji == "👍" && $0.isChosen }
    }

    /// How many 👍 on this message aren't Adam's: in a bot chat, the bot's.
    package var othersThumbsUpCount: Int {
        guard let thumbsUp = reactions.first(where: { $0.emoji == "👍" }) else { return 0 }
        return thumbsUp.count - (thumbsUp.isChosen ? 1 : 0)
    }
}

/// A short, plain description of an error for the UI.
public func userMessage(for error: any Error) -> String {
    if let error = error as? TelegramLinkError {
        switch error {
        case .tdlib(_, let message): return message
        case .notStarted: return "Telegram hasn't started yet."
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
