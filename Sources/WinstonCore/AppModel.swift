import Foundation
import Logging
import LogSupport
import Observation
import TelegramLink
import VoiceLoop
#if os(iOS)
import UIKit
import UserNotifications
#elseif os(macOS)
import AppKit
#endif

/// UserDefaults keys for the settings AppModel persists.
private enum StorageKey {
    static let selectedChatID = "selectedChatID"
    static let pauseThreshold = "pauseThreshold"
    static let voiceIdentifier = "voiceIdentifier"
    static let kokoroModelVariant = "kokoroModelVariant"
    static let speechRate = "speechRate"
    static let speechPitch = "speechPitch"
    static let pausesOtherAudio = "pausesOtherAudio"
    static let pronunciations = "pronunciations"
}

/// Owns all app state: the Telegram session, the bot chats and their messages, and the voice loop.
@MainActor
@Observable
public final class AppModel {
    private static let log = Logger(label: "app.model")

    /// False when `Secrets.xcconfig` is missing, so there is no Telegram session.
    public let hasCredentials: Bool
    public let voiceLoop: VoiceLoop
    public let pushRegistration: PushRegistration
    #if os(iOS)
    public let notificationAccess = NotificationAccess()
    #endif

    public private(set) var authState: AuthState = .starting
    /// Why TDLib failed to start, if it did.
    public private(set) var startError: String?

    public private(set) var chats: [BotChat] = [] {
        didSet { updateAgentWorking() }
    }
    public private(set) var chatsLoaded = false
    public private(set) var chatsError: String?
    /// Each notification tap dismisses the iOS settings sheet, even for the same chat.
    public private(set) var notificationOpenCount = 0
    /// Shown inline, so a picker or preview closing cannot swallow a routing error alert.
    public var notificationErrorMessage: String?
    /// The bot chat shown in the chat screen. Persisted; reset to the first chat if it's no longer a bot chat.
    public var selectedChatID: ChatID? {
        didSet {
            defaults.set(selectedChatID?.rawValue, forKey: StorageKey.selectedChatID)
            updateAgentWorking()
        }
    }
    public private(set) var messages: [ChatID: [ChatMessage]] = [:]
    public private(set) var typingChats: Set<ChatID> = [] {
        didSet { updateAgentWorking() }
    }
    /// The latest 👍 Adam added from this app, set once TDLib's update shows it on its message in the
    /// current chat. The message list scrolls it into view, so it doesn't land behind the bottom bar.
    public private(set) var addedThumbsUp: AddedThumbsUp?
    /// The message Adam is adding a 👍 to from this app, until TDLib's update shows it there.
    @ObservationIgnored private var thumbsUpBeingAdded: (chat: ChatID, message: MessageID)?
    public private(set) var downloadedFiles: [Int32: URL] = [:]
    public private(set) var downloadingFiles: Set<Int32> = []
    /// True while a picked photo or file, or dropped files, are being prepared and handed to TDLib.
    public private(set) var isSendingAttachment = false

    public private(set) var isVoiceMode = false
    /// True while `voiceLoop.start()` runs (permission prompts, model download). The loop stays `.off` until then.
    public private(set) var isStartingVoice = false
    /// Counts the times voice mode was turned off, so `setVoiceMode(_:)` can tell when a quick off-and-on
    /// cancelled the start it is waiting on. Tests read it to tell whether voice mode was turned off again.
    @ObservationIgnored package private(set) var voiceModeOffCount = 0
    /// The chat push-to-talk was entered in. While it is set, what voice mode hears is sent there rather
    /// than to the current chat, so a hold still being sent when another chat opens (a notification
    /// tapped meanwhile) reaches the bot it was said to. Set by `setPushToTalk(true)`, and kept after
    /// leaving push-to-talk, so the utterance the loop sends as it stops still goes there. Cleared when
    /// hands-free voice mode starts, and with the session.
    @ObservationIgnored private var pushToTalkChat: ChatID?
    /// Seconds the transcript must stay unchanged before voice mode sends it. Persisted.
    public var pauseThreshold: Double {
        didSet {
            defaults.set(pauseThreshold, forKey: StorageKey.pauseThreshold)
            logSettingChange(StorageKey.pauseThreshold, from: oldValue, to: pauseThreshold)
            applyVoiceSettings()
        }
    }
    /// The `VoiceOption.id` to speak with, or nil for VoiceLoop's default. Persisted.
    public var voiceIdentifier: String? {
        didSet {
            defaults.set(voiceIdentifier, forKey: StorageKey.voiceIdentifier)
            logSettingChange(StorageKey.voiceIdentifier, from: oldValue ?? "default", to: voiceIdentifier ?? "default")
            applyVoiceSettings()
        }
    }
    /// Which Kokoro model speaks the Kokoro voices, or nil for none, as `VoiceLoop.kokoroModelVariant`.
    /// Persisted, none as `noKokoroModel`.
    public var kokoroModelVariant: KokoroModelVariant? {
        didSet {
            defaults.set(kokoroModelVariant?.rawValue ?? Self.noKokoroModel, forKey: StorageKey.kokoroModelVariant)
            logSettingChange(
                StorageKey.kokoroModelVariant,
                from: oldValue?.rawValue ?? Self.noKokoroModel,
                to: kokoroModelVariant?.rawValue ?? Self.noKokoroModel
            )
            applyVoiceSettings()
        }
    }
    /// How `kokoroModelVariant` is saved when no model is chosen. With nothing saved, the default
    /// model is chosen.
    private static let noKokoroModel = "none"
    /// How fast replies are spoken, as a `VoiceLoop.speechRate`. Persisted.
    public var speechRate: Float {
        didSet {
            defaults.set(speechRate, forKey: StorageKey.speechRate)
            logSettingChange(StorageKey.speechRate, from: oldValue, to: speechRate)
            applyVoiceSettings()
        }
    }
    /// How high replies are spoken, as a `VoiceLoop.speechPitch` multiplier (1 is normal). Persisted.
    public var speechPitch: Float {
        didSet {
            defaults.set(speechPitch, forKey: StorageKey.speechPitch)
            logSettingChange(StorageKey.speechPitch, from: oldValue, to: speechPitch)
            applyVoiceSettings()
        }
    }
    /// Whether voice mode may pause or turn down other apps' audio, such as music. Persisted.
    public var pausesOtherAudio: Bool {
        didSet {
            defaults.set(pausesOtherAudio, forKey: StorageKey.pausesOtherAudio)
            logSettingChange(StorageKey.pausesOtherAudio, from: oldValue, to: pausesOtherAudio)
            applyVoiceSettings()
        }
    }
    /// Words said differently, as `VoiceLoop.pronunciations`, in the order settings lists them: a Say As
    /// entry by every voice, an IPA entry by the Kokoro voices only (the system voices say its word as
    /// written). Persisted.
    public var pronunciations: [Pronunciation] {
        didSet {
            do {
                defaults.set(try JSONEncoder().encode(pronunciations), forKey: StorageKey.pronunciations)
            } catch {
                Self.log.error("saving pronunciations failed", error.logCodes())
            }
            applyVoiceSettings()
        }
    }
    /// A user-facing error from the last action. The chat screen shows it in an alert.
    public var errorMessage: String?

    /// Nil without credentials, and in previews. One instance for the app's lifetime: once started it must
    /// never be deallocated, because TDLib's client manager blocks while tearing down.
    private let link: TelegramLink?
    /// Suggests phonemes for an IPA pronunciation's word in settings.
    private let pronunciationSuggester: any PronunciationSuggester
    /// Where the settings persist.
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var started = false
    @ObservationIgnored private var isLoadingChats = false
    @ObservationIgnored private var reloadChatsForNotification = false
    @ObservationIgnored private var pendingNotification: TelegramNotification?
    @ObservationIgnored private var sessionGeneration = 0
    /// Whether the app is in the foreground, which TDLib's `online` option follows once logged in.
    @ObservationIgnored private var isAppActive = false
    /// The latest request to set TDLib's `online` option. Each waits for the one before, so they
    /// reach TDLib in the order the app came and went.
    @ObservationIgnored private var onlineStatusTask: Task<Void, Never>?
    /// The observers of the app coming and going, removed with the model (the tests make many).
    @ObservationIgnored private var lifecycleObservers: [any NSObjectProtocol] = []

    /// The app's model: a Telegram session if `Secrets.xcconfig` supplied credentials, the real voice loop, and
    /// the standard user defaults.
    public convenience init() {
        self.init(voiceLoop: VoiceLoop(), defaults: .standard)
    }

    /// The app's model with a Telegram session if `Secrets.xcconfig` supplied credentials. Tests pass a voice
    /// loop on a test bed and defaults of their own, so the real Kokoro model and settings are left alone.
    package convenience init(voiceLoop: VoiceLoop, defaults: UserDefaults) {
        self.init(
            link: AppSecrets.load().map { TelegramLink(config: Self.telegramConfig($0)) },
            voiceLoop: voiceLoop,
            defaults: defaults
        )
    }

    /// Tests pass a link over a fake TDLib, a voice loop on offline audio, defaults of their own, and
    /// a fake pronunciation suggester. `hasCredentials` defaults to whether there is a link; only
    /// previews have one without the other.
    package init(
        link: TelegramLink?,
        voiceLoop: VoiceLoop,
        defaults: UserDefaults,
        hasCredentials: Bool? = nil,
        pronunciationSuggester: any PronunciationSuggester = OnDevicePronunciationSuggester()
    ) {
        self.link = link
        pushRegistration = PushRegistration(link: link)
        self.voiceLoop = voiceLoop
        self.defaults = defaults
        self.hasCredentials = hasCredentials ?? (link != nil)
        self.pronunciationSuggester = pronunciationSuggester
        selectedChatID = (defaults.object(forKey: StorageKey.selectedChatID) as? Int64).map(ChatID.init)
        pauseThreshold = defaults.object(forKey: StorageKey.pauseThreshold) as? Double ?? 1.2
        voiceIdentifier = defaults.string(forKey: StorageKey.voiceIdentifier)
        kokoroModelVariant = Self.savedKokoroModelVariant(in: defaults)
        speechRate = defaults.object(forKey: StorageKey.speechRate) as? Float ?? VoiceLoop.defaultSpeechRate
        speechPitch = defaults.object(forKey: StorageKey.speechPitch) as? Float ?? VoiceLoop.defaultSpeechPitch
        pausesOtherAudio = defaults.object(forKey: StorageKey.pausesOtherAudio) as? Bool ?? true
        pronunciations = Self.savedPronunciations(in: defaults)
        applyVoiceSettings()
        // After the saved voice is set: a Kokoro voice keeps its model.
        voiceLoop.removeUnusedKokoroModel()
        observeAppActivation()
        // AirPods connecting or taken out end voice mode in the loop; the app leaves it too.
        voiceLoop.onStoppedForDeviceChange = { [weak self] in
            self?.leaveVoiceMode()
        }
    }

    isolated deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    #if DEBUG
    /// A model with sample data and no Telegram session, for SwiftUI previews.
    public convenience init(previewChats: [BotChat], messages: [ChatID: [ChatMessage]], authState: AuthState) {
        self.init(previewChats: previewChats, messages: messages, authState: authState, voiceLoop: VoiceLoop(), defaults: .standard)
    }

    /// The same, on the voice loop and defaults a test passes.
    package convenience init(
        previewChats: [BotChat],
        messages: [ChatID: [ChatMessage]],
        authState: AuthState,
        voiceLoop: VoiceLoop,
        defaults: UserDefaults
    ) {
        self.init(link: nil, voiceLoop: voiceLoop, defaults: defaults, hasCredentials: true)
        self.authState = authState
        chats = previewChats
        chatsLoaded = true
        self.messages = messages
        selectedChatID = previewChats.first?.id
    }
    #endif

    /// Logs a voice setting changed to `value`, by its storage key, so the logs say what a reply
    /// or preview was spoken with. Nothing if it is unchanged. A slider logs each step it passes.
    private func logSettingChange<Value: Equatable & CustomStringConvertible>(_ setting: String, from old: Value, to value: Value) {
        guard value != old else { return }
        Self.log.info("setting changed", ["setting": setting, "from": old, "to": value])
    }

    private func applyVoiceSettings() {
        voiceLoop.pauseThreshold = .seconds(pauseThreshold)
        // Before the voice: choosing a Kokoro voice loads the model chosen by then.
        voiceLoop.kokoroModelVariant = kokoroModelVariant
        voiceLoop.voiceIdentifier = voiceIdentifier
        voiceLoop.speechRate = speechRate
        voiceLoop.speechPitch = speechPitch
        voiceLoop.pausesOtherAudio = pausesOtherAudio
        voiceLoop.pronunciations = pronunciations
    }

    /// The Kokoro model saved in `defaults`: nil if none was chosen, and the default model if
    /// nothing is saved or it names no model.
    private static func savedKokoroModelVariant(in defaults: UserDefaults) -> KokoroModelVariant? {
        let saved = defaults.string(forKey: StorageKey.kokoroModelVariant)
        if saved == noKokoroModel { return nil }
        return saved.flatMap(KokoroModelVariant.init(rawValue:)) ?? VoiceLoop.defaultKokoroModelVariant
    }

    /// The pronunciations saved in `defaults`, or none if there are none or they can't be read.
    private static func savedPronunciations(in defaults: UserDefaults) -> [Pronunciation] {
        guard let data = defaults.data(forKey: StorageKey.pronunciations) else { return [] }
        do {
            return try JSONDecoder().decode([Pronunciation].self, from: data)
        } catch {
            log.error("saved pronunciations unreadable; starting with none", error.logCodes())
            return []
        }
    }

    /// Each activation, and each time the app leaves the foreground (to the background on iOS, or
    /// to another app on macOS), goes to `appDidBecomeActive()` or `appDidLeaveForeground()` as
    /// the system posts it. Main-queue observers keep them in the order they came, which an
    /// activation's slower work below must not hold up.
    ///
    /// Each activation also removes unused Kokoro models and, on iOS, logs the alerts in
    /// Notification Center and refreshes notification permission, requesting the current APNs
    /// token. Scene-based apps post these notifications even though they don't call the
    /// UIApplicationDelegate methods.
    private func observeAppActivation() {
        #if os(iOS)
        let becameActive = UIApplication.didBecomeActiveNotification
        let leftForeground = UIApplication.didEnterBackgroundNotification
        #elseif os(macOS)
        let becameActive = NSApplication.didBecomeActiveNotification
        let leftForeground = NSApplication.didResignActiveNotification
        #endif
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: becameActive, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appDidBecomeActive() }
            },
            center.addObserver(forName: leftForeground, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appDidLeaveForeground() }
            },
        ]
        let activations = center.notifications(named: becameActive)
        Task { [weak self] in
            for await _ in activations {
                guard let self else { return }
                self.voiceLoop.removeUnusedKokoroModel()
                #if os(iOS)
                await self.logAlertsInNotificationCenter()
                await self.notificationAccess.refresh()
                #endif
            }
        }
    }

    /// The app came to the foreground. Package so the tests can call it in place of the system's
    /// notification, which would reach every test's model.
    package func appDidBecomeActive() {
        Self.log.notice("app became active", [
            "authState": authState.logName,
            "chatsLoaded": chatsLoaded,
            "newestShownIDs": newestShownIDs,
        ])
        isAppActive = true
        sendOnlineStatus()
    }

    /// The app left the foreground. Package for the tests, as `appDidBecomeActive()` is.
    package func appDidLeaveForeground() {
        Self.log.notice("app left the foreground", [
            "authState": authState.logName,
            "newestShownIDs": newestShownIDs,
        ])
        isAppActive = false
        sendOnlineStatus()
    }

    /// Tells TDLib whether the app is in the foreground (see `TelegramLink.setOnline(_:)`), so
    /// that coming back replaces a dead connection at once and TDLib fetches what arrived
    /// meanwhile. Only once logged in: TDLib's account status needs an account.
    private func sendOnlineStatus() {
        guard let link, authState == .ready else { return }
        let isOnline = isAppActive
        let previous = onlineStatusTask
        onlineStatusTask = Task {
            await previous?.value
            do {
                try await link.setOnline(isOnline)
                Self.log.notice("telegram online status set", ["online": isOnline])
            } catch {
                Self.log.error("setting telegram online status failed", error.logContext(["online": String(isOnline)]))
            }
        }
    }

    #if os(iOS)
    /// Logs each Telegram alert still in Notification Center: what arrived while the app was away,
    /// when, and whether its message is shown yet. A tapped alert leaves Notification Center, and
    /// `openNotification(_:)` logs it instead. Not in `appDidBecomeActive()`: a test process has no
    /// app bundle for `UNUserNotificationCenter`.
    private func logAlertsInNotificationCenter() async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        Self.log.notice("alerts in notification center", ["count": delivered.count])
        for notification in delivered {
            guard let target = TelegramNotification(userInfo: notification.request.content.userInfo) else {
                Self.log.info("alert in notification center", ["chatID": "notPrivate"])
                continue
            }
            Self.log.info("alert in notification center", [
                "chatID": target.chatID,
                "messageID": target.messageID?.description ?? "none",
                "deliveredSecondsAgo": Int(-notification.date.timeIntervalSinceNow),
                "botChat": isBotChat(target.chatID),
                "messageShown": target.messageID.map { isShown($0, in: target.chatID) }?.description ?? "unknown",
            ])
        }
    }
    #endif

    /// Says a sample sentence in the chosen voice, speed and pitch, for the settings voice picker and the
    /// speed and pitch sliders. Says nothing for a Kokoro voice whose model isn't ready yet, rather than
    /// name it in another voice; settings shows the model's download instead. Either way it cuts off the
    /// preview before.
    public func previewVoice() {
        // A voice not on offer in this language isn't used: the best system voice speaks instead.
        let voice = voiceLoop.chosenVoice ?? voiceLoop.voices.first { $0.engine == .system }
        if voice?.engine == .kokoro, voiceLoop.kokoroModelState != .ready {
            // The preview before would carry on in the voice just replaced.
            voiceLoop.stopPreview()
            return
        }
        let name = voice?.name ?? "default"
        voiceLoop.preview("This is how I sound with the \(name) voice.")
    }

    /// Deletes every stored Kokoro model, for settings, and chooses no model, so none downloads
    /// again until one is chosen. Until then the best system voice speaks for a Kokoro voice.
    public func deleteKokoroModels() {
        // First, so the deletion finds no model to download again.
        kokoroModelVariant = nil
        voiceLoop.deleteKokoroModels()
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
                // To the chat push-to-talk was entered in, if it was (see `pushToTalkChat`).
                guard let chat = pushToTalkChat ?? currentChat?.id else { continue }
                await sendText(utterance.messageText, to: chat)
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
        pushRegistration.setAuthorized(state == .ready)
        switch state {
        case .ready:
            sendOnlineStatus()
            Task { await loadChats() }
        case .loggingOut, .closed:
            clearSession()
        default:
            break
        }
    }

    private func clearSession() {
        sessionGeneration += 1
        pendingNotification = nil
        reloadChatsForNotification = false
        notificationErrorMessage = nil
        pushToTalkChat = nil
        if isVoiceMode {
            voiceLoop.stop()
            voiceLoop.isPushToTalk = false
            isVoiceMode = false
        }
        chats = []
        chatsLoaded = false
        chatsError = nil
        messages = [:]
        typingChats = []
        addedThumbsUp = nil
        thumbsUpBeingAdded = nil
        downloadedFiles = [:]
    }

    // MARK: - Chats

    /// A tap can arrive before SwiftUI appears or before Telegram has restored its session.
    /// Keep it until the bot list is loaded; never start voice mode from a notification.
    public func openNotification(_ notification: TelegramNotification) {
        Self.log.notice("opening notification", [
            "chatID": notification.chatID,
            "messageID": notification.messageID?.description ?? "none",
            "authState": authState.logName,
            "chatsLoaded": chatsLoaded,
            // Whether the alert's message is already shown, so a missed one stands out.
            "messageShown": notification.messageID.map { isShown($0, in: notification.chatID) }?.description ?? "unknown",
        ])
        notificationOpenCount += 1
        notificationErrorMessage = nil
        pendingNotification = notification
        start()
        if authState == .ready {
            Task {
                if isBotChat(notification.chatID) {
                    await openPendingNotification()
                } else {
                    await loadChats()
                }
            }
        }
    }

    private func openPendingNotification() async {
        guard authState == .ready, let notification = pendingNotification, let link else { return }
        let generation = sessionGeneration
        do {
            if let accountID = notification.accountID {
                let currentAccount = try await link.currentUserID()
                guard generation == sessionGeneration, pendingNotification == notification else { return }
                if accountID != currentAccount {
                    pendingNotification = nil
                    notificationErrorMessage = "This notification belongs to a different Telegram account."
                    return
                }
            }
            guard authState == .ready, generation == sessionGeneration,
                  pendingNotification == notification else { return }
            pendingNotification = nil
            if isBotChat(notification.chatID) {
                selectedChatID = notification.chatID
            } else {
                notificationErrorMessage = "This chat isn't available in Winston. Open it in Telegram."
            }
        } catch {
            Self.log.error("opening notification failed", error.tdlibLogCodes())
            guard generation == sessionGeneration, pendingNotification == notification else { return }
            notificationErrorMessage = "Couldn't open the notification. Please try again."
        }
    }

    public var currentChat: BotChat? {
        chats.first { $0.id == selectedChatID }
    }

    public var currentMessages: [ChatMessage] {
        currentChat.flatMap { messages[$0.id] } ?? []
    }

    public var isBotTyping: Bool {
        currentChat.map { typingChats.contains($0.id) } ?? false
    }

    /// Tells the voice loop whether the bot in the current chat is typing a reply, for the taps it
    /// plays once when typing starts. Called whenever `typingChats`, `selectedChatID` or `chats`
    /// change. The loop plays nothing while voice mode is off, so this needs no check for it.
    /// Typing ends with the bot's message, typing's own end or its timeout.
    private func updateAgentWorking() {
        voiceLoop.isAgentWorking = isBotTyping
    }

    /// The bot's latest message in the current chat.
    public var latestIncomingMessage: ChatMessage? {
        currentMessages.last { !$0.isOutgoing }
    }

    /// Loads the bot chats and their recent history.
    public func loadChats() async {
        guard let link else { return }
        guard !isLoadingChats else {
            // A tap may name a new bot that wasn't in this load's chat-list snapshot.
            // Coalesce those requests into one fresh load after the history work finishes.
            if pendingNotification != nil { reloadChatsForNotification = true }
            return
        }
        let generation = sessionGeneration
        isLoadingChats = true
        Self.log.info("chat load started")
        defer {
            isLoadingChats = false
            let needsReload = (reloadChatsForNotification && pendingNotification != nil)
                || generation != sessionGeneration
            reloadChatsForNotification = false
            if needsReload, authState == .ready {
                Task { await loadChats() }
            }
        }
        chatsError = nil
        do {
            // botChats() lists every bot chat by recency. Drop @BotFather and sort by title so the picker is stable.
            let loadedChats = try await link.botChats()
                .filter { $0.username?.lowercased() != "botfather" }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            guard generation == sessionGeneration else { return }
            Self.log.info("bot chats loaded", ["count": loadedChats.count])
            chats = loadedChats
            chatsLoaded = true
            if currentChat == nil {
                selectedChatID = chats.first?.id
            }
            // Use this fresh snapshot immediately when it contains the tapped bot.
            // Only an unresolved target needs the queued refresh after history loads.
            if !reloadChatsForNotification || pendingNotification.map({ isBotChat($0.chatID) }) == true {
                await openPendingNotification()
            }
        } catch {
            Self.log.error("loading bot chats failed", error.logContext())
            guard generation == sessionGeneration else { return }
            chatsError = userMessage(for: error)
            return
        }
        guard generation == sessionGeneration else { return }
        for chat in chats {
            do {
                let history = try await link.history(in: chat.id, limit: 50)
                guard generation == sessionGeneration else { return }
                // Keep anything that arrived as an event while the history was loading.
                let historyIDs = Set(history.map(\.id))
                let shown = messages[chat.id] ?? []
                let newer = shown.filter { !historyIDs.contains($0.id) }
                messages[chat.id] = history + newer
                let shownIDs = Set(shown.map(\.id))
                // Messages the history had that the model didn't show yet, such as one TDLib
                // delivered before the bot chats loaded.
                let added = history.filter { !shownIDs.contains($0.id) }
                Self.log.info("chat history merged", [
                    "chatID": chat.id,
                    "shownBefore": shown.count,
                    "read": history.count,
                    "added": added.count,
                    // The newest few by ID, to match with an alert or an ignored message.
                    "newestAddedIDs": added.suffix(10).map(\.id.description).joined(separator: ","),
                    "keptFromEvents": newer.count,
                    "newestID": messages[chat.id]?.last?.id.rawValue ?? 0,
                ])
            } catch {
                Self.log.error("loading chat history failed", error.logContext(["chatID": chat.id.description]))
                guard generation == sessionGeneration else { return }
                errorMessage = "Couldn't load the history for \(chat.title): \(userMessage(for: error))"
            }
        }
    }

    private func isBotChat(_ chat: ChatID) -> Bool {
        chats.contains { $0.id == chat }
    }

    private func isShown(_ message: MessageID, in chat: ChatID) -> Bool {
        messages[chat]?.contains { $0.id == message } ?? false
    }

    /// Each bot chat's newest shown message ID, as `chatID:messageID` pairs, for the lifecycle
    /// logs: comparing them before and after the app was away shows what arrived meanwhile.
    private var newestShownIDs: String {
        chats.map { "\($0.id):\(messages[$0.id]?.last?.id.description ?? "none")" }.joined(separator: ",")
    }

    private func handle(_ event: ChatEvent) {
        switch event {
        case .newMessage(let message):
            guard isBotChat(message.chatID) else {
                logIgnoredMessage(message)
                return
            }
            let isNew = upsert(message, replacing: message.id)
            Self.log.info(isNew ? "message delivered" : "message already shown, replaced", [
                "chatID": message.chatID,
                "messageID": message.id,
                "outgoing": message.isOutgoing,
                "pending": message.sendState == .pending,
                "currentChat": message.chatID == currentChat?.id,
            ])
            if !message.isOutgoing {
                typingChats.remove(message.chatID)
                if isNew, isVoiceMode, message.chatID == currentChat?.id {
                    speak(message)
                }
            }
        case .reactionsChanged(let chat, let id, let reactions):
            var botAddedReaction = false
            var showsMyThumbsUp = false
            updateMessage(id, in: chat) { message in
                let before = message.othersReactionCounts
                message.reactions = reactions
                botAddedReaction = message.othersReactionCounts.contains { $0.value > before[$0.key, default: 0] }
                showsMyThumbsUp = message.hasMyThumbsUp
            }
            // In voice mode Adam may not be looking, so the bot's reaction in the chat he's in chimes. Every
            // emoji plays the same chime.
            if botAddedReaction, isVoiceMode, chat == currentChat?.id {
                voiceLoop.play(.reaction)
            }
            if showsMyThumbsUp, let adding = thumbsUpBeingAdded, adding == (chat, id) {
                thumbsUpBeingAdded = nil
                if chat == currentChat?.id {
                    addedThumbsUp = AddedThumbsUp(messageID: id, number: (addedThumbsUp?.number ?? 0) + 1)
                }
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
            let isNew = upsert(message, replacing: oldID)
            Self.log.info("sent message confirmed", [
                "chatID": chat,
                "oldID": oldID,
                "messageID": message.id,
                // False means the pending message wasn't shown, so the sent one was added.
                "replacedPending": !isNew,
            ])
        case .sendFailed(let chat, let id, let error):
            updateMessage(id, in: chat) { $0.sendState = .failed(error) }
        }
    }

    /// Logs a new message the model ignores because its chat isn't a loaded bot chat. Until the
    /// bot chats first load, that ignores a bot's message too (the history load should pick it up
    /// again), so those go where the log file keeps them; later ones, from other chats, only at debug.
    private func logIgnoredMessage(_ message: ChatMessage) {
        let metadata: [String: CustomStringConvertible] = [
            "chatID": message.chatID,
            "messageID": message.id,
            "outgoing": message.isOutgoing,
        ]
        if chatsLoaded {
            Self.log.debug("message ignored: not a bot chat", metadata)
        } else {
            Self.log.notice("message ignored: bot chats not loaded yet", metadata)
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
        guard let chat = currentChat else { return false }
        return await sendText(text, to: chat.id)
    }

    /// The same, to `chat` whichever chat is shown: for what push-to-talk heard (see `pushToTalkChat`).
    @discardableResult
    private func sendText(_ text: String, to chat: ChatID) async -> Bool {
        guard let link else { return false }
        do {
            try await link.sendText(text, to: chat)
            return true
        } catch {
            Self.log.error("sending text failed", error.logContext(["chatID": chat.description]))
            errorMessage = userMessage(for: error)
            return false
        }
    }

    /// Sends a picked photo, downscaled and re-encoded as JPEG, with an optional caption.
    /// `loadData` loads the picked photo's data; in the app it is `PhotosPickerItem.loadTransferable`, which
    /// returns nil when the photo can't be read. Returns false and sets `errorMessage` on failure.
    public func sendPhoto(caption: String, loadData: () async throws -> Data?) async -> Bool {
        guard let link, let chat = currentChat else { return false }
        isSendingAttachment = true
        defer { isSendingAttachment = false }
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

    /// Sends files as documents to the current chat, one message each in order, under their own names,
    /// with an optional caption on the first. `fileURLs` are the file picker's URL, or the files dropped
    /// on the window. Sets `errorMessage` on failure.
    ///
    /// Each file is copied first (see `DocumentFiles.copyForSending`), and if any can't be, none is
    /// sent. If TDLib turns one down, the ones after it aren't sent. Returns whether the first file, and
    /// so the caption, was sent: true when all were, and also when a later one was turned down.
    public func sendDocuments(caption: String, fileURLs: [URL]) async -> Bool {
        // The chat is the one shown now, even if Adam switches chats while the files are copied.
        guard let link, let chat = currentChat, !fileURLs.isEmpty else { return false }
        isSendingAttachment = true
        defer { isSendingAttachment = false }
        var copies: [URL] = []
        do {
            for fileURL in fileURLs {
                copies.append(try await DocumentFiles.copyForSending(from: fileURL))
            }
        } catch {
            // Nothing will upload the copies made so far, and they can be large.
            copies.forEach(DocumentFiles.removeCopy)
            showDocumentError(error, chat: chat)
            return false
        }
        for (index, copy) in copies.enumerated() {
            do {
                // TDLib uploads after sendDocument returns, and the sent message's document can keep
                // pointing at its copy, so a sent copy stays in the temporary directory for the system
                // to clean up.
                try await link.sendDocument(fileURL: copy, caption: index == 0 && !caption.isEmpty ? caption : nil, to: chat.id)
            } catch {
                // TDLib turned it down, so nothing will upload it or the ones after it.
                copies[index...].forEach(DocumentFiles.removeCopy)
                showDocumentError(error, chat: chat)
                return index > 0
            }
        }
        return true
    }

    private func showDocumentError(_ error: any Error, chat: BotChat) {
        // Codes only: a file error's description names the file, and a TDLib upload error's
        // message can hold the local path.
        Self.log.error("sending document failed", error.tdlibLogCodes(["chatID": chat.id.description]))
        errorMessage = userMessage(for: error)
    }

    /// Adds Adam's 👍 to `message`, or removes it. An added 👍 becomes `addedThumbsUp` once it shows.
    public func toggleThumbsUp(on message: ChatMessage) async {
        guard let link else { return }
        // Noted before the request: TDLib's update can arrive before toggleReaction returns.
        if !message.hasMyThumbsUp {
            thumbsUpBeingAdded = (message.chatID, message.id)
        }
        do {
            try await link.toggleReaction("👍", on: message.id, in: message.chatID)
        } catch {
            Self.log.error("toggling reaction failed", error.logContext([
                "chatID": message.chatID.description,
                "messageID": message.id.description,
            ]))
            errorMessage = userMessage(for: error)
            if let adding = thumbsUpBeingAdded, adding == (message.chatID, message.id) {
                thumbsUpBeingAdded = nil
            }
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
            if !voiceLoop.isPushToTalk {
                // Hands-free, what is heard goes to the chat shown.
                pushToTalkChat = nil
            }
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
                voiceLoop.isPushToTalk = false
                isVoiceMode = false
                errorMessage = userMessage(for: error)
            }
        } else {
            leaveVoiceMode()
        }
    }

    /// Turns voice mode off, push-to-talk included, for `setVoiceMode(false)` and for when the
    /// loop ended it because the audio devices changed.
    private func leaveVoiceMode() {
        voiceModeOffCount += 1
        voiceLoop.stop()
        voiceLoop.isPushToTalk = false
        isVoiceMode = false
    }

    /// Enters or leaves push-to-talk, for the push-to-talk sheet, which opens from text mode.
    /// Entering starts voice mode, as `setVoiceMode(true)` does, with the loop in push-to-talk:
    /// it hears only what is said while `voiceLoop.beginTalking()` to `voiceLoop.endTalking()`
    /// hold the button, and sends it after the release. Replies are spoken as in voice mode.
    /// Leaving stops voice mode and returns to text mode. Push-to-talk ends whenever voice mode
    /// does, so a failed start leaves it off.
    ///
    /// What it hears goes to the chat shown when it was entered, even once another chat is shown
    /// (see `pushToTalkChat`).
    public func setPushToTalk(_ on: Bool) async {
        if on {
            pushToTalkChat = currentChat?.id
            voiceLoop.isPushToTalk = true
            await setVoiceMode(true)
        } else {
            // The sheet's dismissal also comes once voice mode has ended without it, as after a
            // change of audio devices. Stopping the loop again then could cut off its stop cue.
            guard isVoiceMode || voiceLoop.isPushToTalk else { return }
            await setVoiceMode(false)
        }
    }

    private func speak(_ message: ChatMessage) {
        let text = message.spokenText
        guard !text.isEmpty else { return }
        voiceLoop.speak(text)
    }

    /// Says `message` again, for the message list's Speak menu item: in the chosen voice, Kokoro model,
    /// speed and pitch, cutting off whatever was being said, with voice mode on or off, as a voice preview
    /// does. A Kokoro voice whose model isn't ready yet speaks with the system voice, as a reply would.
    public func readAloud(_ message: ChatMessage) {
        let text = message.spokenText
        guard !text.isEmpty else { return }
        voiceLoop.preview(text)
    }

    /// Plays one side of a pronunciation in settings, its word or its replacement, trimmed but otherwise
    /// exactly as written, as `readAloud(_:)` plays a message. Played as written, the word comes out as
    /// the voice would say it with no pronunciation, so it can be compared with its replacement. Nothing
    /// when `text` is blank, so whatever is being said carries on.
    public func previewPronunciation(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        voiceLoop.preview(asWritten: text)
    }

    /// Plays `word` said with `phonemes`, both trimmed, as `previewPronunciation(_:)` plays text: for an
    /// IPA pronunciation's phonemes in settings, saved or not. A Kokoro voice whose model is ready says the
    /// phonemes; any other voice says the word as written, as it would in a reply. Nothing when either is
    /// blank, so whatever is being said carries on.
    public func previewPronunciation(word: String, phonemes: String) {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let phonemes = phonemes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !phonemes.isEmpty else { return }
        voiceLoop.preview(word: word, phonemes: phonemes)
    }

    /// Whether settings offers the Suggest button on an IPA pronunciation: the suggester can run
    /// now. The on-device one can't without Apple Intelligence, while it is turned off, or while
    /// its model downloads.
    public var canSuggestPronunciations: Bool {
        pronunciationSuggester.isAvailable
    }

    /// The suggested pronunciations of `word`, trimmed, for the list the Suggest button opens. It
    /// asks nothing until its `generate()` is called. Each candidate is checked against the
    /// phoneme symbols Kokoro has as the suggester answers.
    public func pronunciationSuggestions(for word: String) -> PronunciationSuggestions {
        PronunciationSuggestions(word: word, suggester: pronunciationSuggester) { [voiceLoop] in
            await voiceLoop.kokoroPhonemeSymbols()
        }
    }

    /// Fills the pronunciation with `id` with `candidate`'s phonemes, as IPA, and saves it, for the
    /// suggestion list's Use button. Returns whether it did: not for a candidate with a symbol
    /// Kokoro doesn't have, nor once the pronunciation is gone.
    @discardableResult
    public func use(_ candidate: PronunciationCandidate, forPronunciation id: Pronunciation.ID) -> Bool {
        guard candidate.isUsable, let index = pronunciations.firstIndex(where: { $0.id == id }) else { return false }
        pronunciations[index].replacement = candidate.suggestion.phonemes
        pronunciations[index].mode = .phonetic
        return true
    }
}

/// A 👍 Adam added from this app, once it shows on its message: what `AppModel.addedThumbsUp` holds.
public struct AddedThumbsUp: Equatable, Sendable {
    public let messageID: MessageID
    /// Counts the 👍s added, so adding one to the same message again is a change too.
    let number: Int
}

extension ChatMessage {
    /// What voice mode says for this message: its attachment, if any ("Photo", or "File: " and its
    /// name), then its text. Empty for a message with neither.
    public var spokenText: String {
        let label: String? = switch attachment {
        case nil: nil
        case .photo: "Photo"
        case .document(_, let fileName, _, _): "File: \(fileName)"
        }
        return [label, text]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }

    /// Whether Adam's own 👍 is on this message: what `AppModel.toggleThumbsUp(on:)` flips.
    public var hasMyThumbsUp: Bool {
        reactions.contains { $0.emoji == "👍" && $0.isChosen }
    }

    /// How many of each emoji on this message aren't Adam's: in a bot chat, the bot's. An emoji only
    /// Adam chose counts 0.
    package var othersReactionCounts: [String: Int] {
        Dictionary(reactions.map { ($0.emoji, $0.count - ($0.isChosen ? 1 : 0)) }, uniquingKeysWith: +)
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
    if let error = error as? DocumentFiles.Failure {
        switch error {
        case .folder: return "Winston can send files, but not folders."
        }
    }
    if let error = error as? PronunciationSuggestionError {
        switch error {
        case .unavailable: return "Suggestions aren't available right now. Check that Apple Intelligence is turned on and its model has downloaded."
        case .declined: return "The model declined to suggest pronunciations for this word."
        case .busy: return "The model is busy. Try again in a moment."
        case .failed: return "Couldn't get suggestions. Try again."
        }
    }
    return error.localizedDescription
}
