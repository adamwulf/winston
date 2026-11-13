import Foundation
import Testing
import TelegramLink
import TelegramLinkTestSupport
import VoiceLoop
import VoiceLoopTestSupport
import WinstonCore

/// Logging in, and the chats and history that load once the session is ready.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionTests {
    @Test func onceLoggedInTheBotChatsLoadSortedByTitleWithTheirHistory() async throws {
        let harness = Harness.withTwoBots()
        // BotFather is a bot chat too, but not one of Adam's bots.
        harness.fake.addBotChat(id: 3, title: "BotFather", username: "BotFather")
        let model = harness.model
        #expect(model.hasCredentials)
        #expect(model.authState == .starting)

        #expect(await harness.startAndLoadChats())

        #expect(model.chats == [
            BotChat(id: ChatID(1), title: "Home", username: "home_bot"),
            BotChat(id: ChatID(2), title: "Laptop", username: "laptop_bot"),
        ])
        #expect(model.chatsError == nil)
        // The first chat is selected, and the choice is saved.
        #expect(model.selectedChatID == ChatID(1))
        #expect(harness.defaults.object(forKey: "selectedChatID") as? Int64 == 1)
        #expect(model.currentChat?.title == "Home")
        #expect(model.currentMessages.map(\.text) == ["What's on the build server?", "Two jobs are queued."])
        #expect(model.latestIncomingMessage?.text == "Two jobs are queued.")
        #expect(model.messages[ChatID(2)]?.map(\.text) == ["The coordinator is offline."])
    }

    @Test func startingTwiceStartsOneSession() async throws {
        let harness = Harness.withTwoBots()
        harness.model.start()

        #expect(await harness.startAndLoadChats())
        try await settle()

        #expect(harness.fake.clientCount == 1)
        let requests = harness.fake.requests
        #expect(requests.filter { $0 == .execute("setLogVerbosityLevel") }.count == 1)
        #expect(requests.filter { $0 == .getChats(limit: 100) }.count == 1)
    }

    @Test func aLoggedOutAccountLogsInWithPhoneNumberCodeAndPassword() async throws {
        let harness = Harness(fake: FakeTDLib(isLoggedIn: false, passwordHint: "first dog"))
        let model = harness.model
        model.start()
        #expect(await eventually { model.authState == .needsPhoneNumber })

        try await model.submitPhoneNumber("+15551234567")
        #expect(await eventually { model.authState == .needsCode })

        try await model.submitCode("12345")
        #expect(await eventually { model.authState == .needsPassword(hint: "first dog") })

        try await model.submitPassword("hunter2")
        #expect(await eventually { model.authState == .ready && model.chatsLoaded })

        let login = harness.fake.requests.filter {
            switch $0 {
            case .setAuthenticationPhoneNumber, .checkAuthenticationCode, .checkAuthenticationPassword: true
            default: false
            }
        }
        #expect(login == [
            .setAuthenticationPhoneNumber("+15551234567"),
            .checkAuthenticationCode("12345"),
            .checkAuthenticationPassword("hunter2"),
        ])
    }

    @Test func aWrongLoginCodeIsThrownToTheCaller() async throws {
        let harness = Harness(fake: FakeTDLib(isLoggedIn: false))
        harness.fake.fail(.checkAuthenticationCode, code: 400, message: "PHONE_CODE_INVALID")
        let model = harness.model
        model.start()
        #expect(await eventually { model.authState == .needsPhoneNumber })
        try await model.submitPhoneNumber("+15551234567")
        #expect(await eventually { model.authState == .needsCode })

        await #expect(throws: TelegramLinkError.tdlib(code: 400, message: "PHONE_CODE_INVALID")) {
            try await model.submitCode("00000")
        }

        #expect(harness.fake.requests.last == .checkAuthenticationCode("00000"))
        #expect(model.authState == .needsCode)
        // The login screen shows it itself; the chat screen's alert stays clear.
        #expect(model.errorMessage == nil)
    }

    @Test func whenTDLibCannotBeSetUpTheStateSaysWhyAndNoChatsLoad() async throws {
        let harness = Harness.withTwoBots()
        harness.fake.fail(.setTdlibParameters, code: 400, message: "Valid api_id must be provided")
        let model = harness.model

        model.start()

        #expect(await eventually {
            model.authState == .unsupported("setTdlibParameters failed: Valid api_id must be provided")
        })
        try await settle()
        #expect(!model.chatsLoaded)
        #expect(model.chats.isEmpty)
        #expect(model.currentChat == nil)
        #expect(!harness.fake.requests.contains(.loadChats(limit: 100)))
    }

    @Test func loggingOutEndsTheSessionAndClearsWhatItShowed() async throws {
        let harness = Harness.withTwoBots()
        harness.fake.setFile(file(id: 7, downloadedPath: "/tmp/winston-tests/files/photo.jpg"))
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        harness.fake.setTyping(true, in: 1)
        #expect(await eventually { model.isBotTyping })
        let photo = FileRef(id: 7, localPath: nil)
        _ = try await model.download(photo)
        #expect(model.localURL(for: photo) != nil)
        await model.setVoiceMode(true)
        #expect(model.voiceLoop.state == .listening(partial: ""))
        let states = ValueLog { model.authState }

        await model.logOut()

        #expect(await eventually { model.authState == .needsPhoneNumber })
        // TDLib closed the session, and a fresh one is waiting for a phone number.
        #expect(states.values == [.ready, .loggingOut, .closed, .starting, .needsPhoneNumber])
        #expect(harness.fake.requests.contains(.logOut))
        #expect(harness.fake.clientCount == 2)
        #expect(model.chats.isEmpty)
        #expect(!model.chatsLoaded)
        #expect(model.messages.isEmpty)
        #expect(model.currentMessages.isEmpty)
        #expect(model.typingChats.isEmpty)
        #expect(!model.isBotTyping)
        #expect(model.downloadedFiles.isEmpty)
        #expect(model.localURL(for: photo) == nil)
        #expect(!model.isVoiceMode)
        #expect(model.voiceLoop.state == .off)
        #expect(await eventually { harness.bed.recognizer.isCancelled })
        #expect(model.errorMessage == nil)
    }

    @Test func aFailedLogOutShowsTheErrorAndKeepsTheSession() async throws {
        let harness = Harness.withTwoBots()
        harness.fake.fail(.logOut, code: 500, message: "Internal Server Error")
        #expect(await harness.startAndLoadChats())
        let model = harness.model

        await model.logOut()

        #expect(model.errorMessage == "Internal Server Error")
        #expect(harness.fake.requests.last == .logOut)
        try await settle()
        #expect(model.authState == .ready)
        #expect(model.chatsLoaded)
        #expect(model.chats.map(\.title) == ["Home", "Laptop"])
        #expect(model.currentMessages.map(\.text) == ["What's on the build server?", "Two jobs are queued."])
        #expect(harness.fake.clientCount == 1)
    }

    @Test func closingForQuitStopsVoiceModeAndClosesTDLib() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        await model.setVoiceMode(true)

        await model.closeForQuit()

        #expect(model.voiceLoop.state == .off)
        #expect(harness.fake.closeCount == 1)
        #expect(await eventually { model.authState == .closed })
        // No fresh session follows, as one does after a logout.
        try await settle()
        #expect(model.authState == .closed)
        #expect(harness.fake.clientCount == 1)
    }

    @Test func closingForQuitBlockingReturnsOnlyOnceTDLibIsClosed() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        await model.setVoiceMode(true)

        model.closeForQuitBlocking()

        #expect(harness.fake.closeCount == 1)
        #expect(model.voiceLoop.state == .off)
        #expect(await eventually { model.authState == .closed })
        #expect(harness.fake.clientCount == 1)
    }
}

/// The bot chats, the chosen chat, and their history.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ChatsTests {
    @Test func theSavedChatIsChosenAgainWhenItIsStillABotChat() async throws {
        let harness = Harness.withTwoBots(settings: ["selectedChatID": Int64(2)])
        let model = harness.model

        #expect(await harness.startAndLoadChats())

        #expect(model.selectedChatID == ChatID(2))
        #expect(model.currentChat?.title == "Laptop")
        #expect(model.currentMessages.map(\.text) == ["The coordinator is offline."])
    }

    @Test func aSavedChatThatIsNoLongerABotChatIsReplacedByTheFirstChat() async throws {
        let harness = Harness.withTwoBots(settings: ["selectedChatID": Int64(99)])
        let model = harness.model

        #expect(await harness.startAndLoadChats())

        #expect(model.selectedChatID == ChatID(1))
        #expect(model.currentChat?.title == "Home")
        #expect(harness.defaults.object(forKey: "selectedChatID") as? Int64 == 1)
    }

    @Test func choosingAChatSavesItAndTheChatScreenFollows() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        // Laptop's bot is typing; Home is chosen, so the chat screen doesn't show it.
        harness.fake.setTyping(true, in: 2)
        #expect(await eventually { model.typingChats == [ChatID(2)] })
        #expect(!model.isBotTyping)

        model.selectedChatID = ChatID(2)

        #expect(harness.defaults.object(forKey: "selectedChatID") as? Int64 == 2)
        #expect(model.currentChat == BotChat(id: ChatID(2), title: "Laptop", username: "laptop_bot"))
        #expect(model.currentMessages.map(\.text) == ["The coordinator is offline."])
        #expect(model.latestIncomingMessage?.text == "The coordinator is offline.")
        #expect(model.isBotTyping)
        #expect(harness.relaunchedModel().selectedChatID == ChatID(2))
    }

    @Test func withNoBotChatsThereIsNothingToShowOrSendTo() async throws {
        let harness = Harness()
        let model = harness.model

        #expect(await harness.startAndLoadChats())

        #expect(model.chatsLoaded)
        #expect(model.chats.isEmpty)
        #expect(model.selectedChatID == nil)
        #expect(model.currentChat == nil)
        #expect(model.currentMessages.isEmpty)
        #expect(model.latestIncomingMessage == nil)
        #expect(!model.isBotTyping)
        let requests = harness.fake.requests.count
        #expect(await model.sendText("Hello.") == false)
        #expect(harness.fake.requests.count == requests)
        #expect(model.errorMessage == nil)
    }

    @Test func whenTheChatListFailsToLoadItShowsTheErrorAndLoadsOnRetry() async throws {
        let harness = Harness.withTwoBots()
        harness.fake.fail(.getChats, code: 500, message: "Internal Server Error")
        let model = harness.model

        model.start()

        #expect(await eventually { model.chatsError == "Internal Server Error" })
        #expect(!model.chatsLoaded)
        #expect(model.chats.isEmpty)

        harness.fake.succeed(.getChats)
        await model.loadChats()

        #expect(model.chatsError == nil)
        #expect(model.chatsLoaded)
        #expect(model.chats.map(\.title) == ["Home", "Laptop"])
        #expect(model.currentMessages.map(\.text) == ["What's on the build server?", "Two jobs are queued."])
    }

    @Test func whenOneChatsHistoryFailsTheErrorNamesItAndTheOtherChatStillLoads() async throws {
        let harness = Harness.withTwoBots()
        harness.fake.failHistory(of: 1, code: 400, message: "CHAT_ACCESS_DENIED")
        let model = harness.model

        model.start()

        #expect(await eventually { model.messages[ChatID(2)] != nil })
        #expect(model.errorMessage == "Couldn't load the history for Home: CHAT_ACCESS_DENIED")
        #expect(model.messages[ChatID(2)]?.map(\.text) == ["The coordinator is offline."])
        #expect(model.messages[ChatID(1)] == nil)
        #expect(model.chatsLoaded)
        #expect(model.chats.map(\.title) == ["Home", "Laptop"])
    }

    @Test func aMessageThatArrivesWhileTheHistoryLoadsIsKeptAfterItOnce() async throws {
        let harness = Harness.withTwoBots()
        harness.fake.hold(.getChatHistory)
        let model = harness.model
        model.start()
        #expect(await eventually {
            harness.fake.requests.contains(.getChatHistory(chatID: 1, fromMessageID: 0, limit: 50))
        })

        harness.fake.receive(textMessage(id: 12, chatID: 1, "Both jobs are done."))
        #expect(await eventually { model.currentMessages.map(\.text) == ["Both jobs are done."] })
        harness.fake.release(.getChatHistory)

        #expect(await eventually { model.messages[ChatID(2)] != nil })
        #expect(model.currentMessages.map(\.id) == [MessageID(10), MessageID(11), MessageID(12)])
        #expect(model.currentMessages.map(\.text) == [
            "What's on the build server?",
            "Two jobs are queued.",
            "Both jobs are done.",
        ])
    }

    @Test func loadingTheChatsWhileTheyAreLoadingDoesNothing() async throws {
        let harness = Harness.withTwoBots()
        harness.fake.hold(.getChats)
        let model = harness.model
        // Once logged in, the model loads the chats by itself.
        model.start()
        #expect(await eventually { harness.fake.requests.contains(.getChats(limit: 100)) })

        await model.loadChats()

        #expect(harness.fake.requests.filter { $0 == .getChats(limit: 100) }.count == 1)
        #expect(!model.chatsLoaded)
        harness.fake.release(.getChats)
        #expect(await eventually { model.chatsLoaded && model.messages[ChatID(2)] != nil })
        try await settle()
        #expect(harness.fake.requests.filter { $0 == .getChats(limit: 100) }.count == 1)
        #expect(model.chats.map(\.title) == ["Home", "Laptop"])
    }
}
