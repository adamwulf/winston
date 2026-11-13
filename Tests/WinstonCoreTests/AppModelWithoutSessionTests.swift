import Foundation
import Testing
import TelegramLink
import VoiceLoop
import VoiceLoopTestSupport
// For `AppModel.telegramConfig(_:)`, which is internal.
@testable import WinstonCore

// These models have no fake TDLib: the app's own initializer finds no credentials in a test
// process, and the preview one has no session at all. Like `Harness`, they run on a
// `VoiceTestBed` and user defaults of their own, so nothing here reaches the real Kokoro model
// or the standard user defaults.

/// The model with no Telegram session: without credentials, and in SwiftUI previews.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct WithoutSessionTests {
    @Test func withoutCredentialsNothingReachesTelegram() async throws {
        let testDefaults = TestDefaults()
        defer { withExtendedLifetime(testDefaults) {} }
        let model = AppModel(voiceLoop: VoiceTestBed().makeLoop(), defaults: testDefaults.defaults)
        #expect(!model.hasCredentials)
        let message = ChatMessage(
            id: MessageID(11),
            chatID: ChatID(1),
            isOutgoing: false,
            date: Date(timeIntervalSince1970: 0),
            text: "Two jobs are queued."
        )

        model.start()
        await model.loadChats()
        try await settle()
        #expect(model.authState == .starting)
        #expect(!model.chatsLoaded)
        #expect(model.chats.isEmpty)

        #expect(await model.sendText("Hello.") == false)
        var loaded = false
        #expect(await model.sendPhoto(caption: "") {
            loaded = true
            return nil
        } == false)
        #expect(!loaded)
        await #expect(throws: TelegramLinkError.notStarted) {
            try await model.download(FileRef(id: 7, localPath: nil))
        }
        try await model.submitPhoneNumber("+15551234567")
        try await model.submitCode("12345")
        try await model.submitPassword("hunter2")
        await model.logOut()
        await model.toggleThumbsUp(on: message)
        model.markRead(message)
        await model.closeForQuit()
        model.closeForQuitBlocking()

        try await settle()
        #expect(model.errorMessage == nil)
        #expect(model.authState == .starting)
        #expect(model.voiceLoop.state == .off)
    }

    #if DEBUG
    @Test func aPreviewShowsItsSampleChatsAndMessagesWithoutASession() async throws {
        let testDefaults = TestDefaults()
        defer { withExtendedLifetime(testDefaults) {} }
        let chats = [
            BotChat(id: ChatID(1), title: "Home", username: "home_bot"),
            BotChat(id: ChatID(2), title: "Laptop", username: "laptop_bot"),
        ]
        let home = [
            ChatMessage(id: MessageID(10), chatID: ChatID(1), isOutgoing: true, date: Date(timeIntervalSince1970: 0), text: "What's on the build server?"),
            ChatMessage(id: MessageID(11), chatID: ChatID(1), isOutgoing: false, date: Date(timeIntervalSince1970: 60), text: "Two jobs are queued."),
        ]

        let model = AppModel(
            previewChats: chats,
            messages: [ChatID(1): home],
            authState: .ready,
            voiceLoop: VoiceTestBed().makeLoop(),
            defaults: testDefaults.defaults
        )

        #expect(model.hasCredentials)
        #expect(model.authState == .ready)
        #expect(model.chatsLoaded)
        #expect(model.chats == chats)
        #expect(model.selectedChatID == ChatID(1))
        #expect(model.currentChat == chats[0])
        #expect(model.currentMessages == home)
        #expect(model.latestIncomingMessage == home[1])
        // There is no session behind it.
        model.start()
        #expect(await model.sendText("Hello.") == false)
        try await settle()
        #expect(model.authState == .ready)
        #expect(model.chats == chats)
    }
    #endif

    @Test func theTelegramConfigKeepsTDLibsFilesInApplicationSupportAndDescribesTheApp() {
        let config = AppModel.telegramConfig(AppSecrets(apiID: 12345, apiHash: "0123456789abcdef"))

        #expect(config.apiID == 12345)
        #expect(config.apiHash == "0123456789abcdef")
        let applicationSupport = URL.applicationSupportDirectory.pathComponents
        #expect(config.databaseDirectory.pathComponents == applicationSupport + ["Telegram", "db"])
        #expect(config.filesDirectory.pathComponents == applicationSupport + ["Telegram", "files"])
        #expect(config.databaseDirectory.hasDirectoryPath)
        #expect(config.filesDirectory.hasDirectoryPath)
        #expect(!config.deviceModel.isEmpty)
        #expect(!config.systemVersion.isEmpty)
        #expect(!config.applicationVersion.isEmpty)
    }
}
