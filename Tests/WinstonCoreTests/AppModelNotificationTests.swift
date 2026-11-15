import Testing
import TelegramLink
import TelegramLinkTestSupport
import VoiceLoopTestSupport
import WinstonCore

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AppModelNotificationTests {
    @Test func coldLaunchTapWaitsForChatsAndSelectsBotWithoutVoice() async throws {
        let harness = Harness.withTwoBots()
        harness.model.openNotification(try target(chat: "2"))
        #expect(await eventually { harness.model.selectedChatID == ChatID(2) })
        #expect(harness.model.currentChat?.title == "Laptop")
        #expect(!harness.model.isVoiceMode)
    }

    @Test func tapDuringChatLoadIsNotLost() async throws {
        let harness = Harness.withTwoBots()
        harness.fake.hold(.getChats)
        harness.model.start()
        #expect(await eventually { harness.fake.isWaiting(on: .getChats) })
        harness.model.openNotification(try target(chat: "2"))
        harness.fake.release(.getChats)
        #expect(await eventually { harness.model.selectedChatID == ChatID(2) })
    }

    @Test func tapRefreshesBotListForANewChat() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        harness.fake.addBotChat(id: 3, title: "New Bot", username: "new_bot")
        harness.model.openNotification(try target(chat: "3"))
        #expect(await eventually { harness.model.selectedChatID == ChatID(3) })
    }

    @Test func tapWhileHistoryLoadsSelectsTheKnownBot() async throws {
        let harness = Harness.withTwoBots()
        harness.fake.hold(.getChatHistory)
        harness.model.start()
        #expect(await eventually { harness.fake.isWaiting(on: .getChatHistory) })
        harness.model.openNotification(try target(chat: "2"))
        #expect(await eventually { harness.model.selectedChatID == ChatID(2) })
        harness.fake.release(.getChatHistory)
    }

    @Test func alertForAnotherAccountDoesNotChangeChat() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        harness.model.openNotification(try target(chat: "2", account: "1000"))
        #expect(await eventually { harness.model.notificationErrorMessage != nil })
        #expect(harness.model.errorMessage == nil)
        #expect(harness.model.selectedChatID == ChatID(1))
    }

    @Test func alertForTheCurrentAccountOpensTheChat() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        harness.model.openNotification(try target(chat: "2", account: "999"))
        #expect(await eventually { harness.model.selectedChatID == ChatID(2) })
        #expect(harness.model.notificationErrorMessage == nil)
    }

    @Test func nonBotAlertKeepsCurrentChatAndExplains() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        harness.model.openNotification(try target(chat: "99"))
        #expect(await eventually { harness.model.notificationErrorMessage != nil })
        #expect(harness.model.errorMessage == nil)
        #expect(harness.model.selectedChatID == ChatID(1))
    }

    @Test func anotherTapClearsTheInlineRoutingError() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        harness.model.openNotification(try target(chat: "99"))
        #expect(await eventually { harness.model.notificationErrorMessage != nil })
        harness.model.openNotification(try target(chat: "2"))
        #expect(await eventually { harness.model.selectedChatID == ChatID(2) })
        #expect(harness.model.notificationErrorMessage == nil)
    }

    @Test func accountLookupFailureUsesInlineErrorInsteadOfModalAlert() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        harness.fake.fail(.getMe, code: 500, message: "network unavailable")
        harness.model.openNotification(try target(chat: "2", account: "999"))
        #expect(await eventually { harness.model.notificationErrorMessage != nil })
        #expect(harness.model.errorMessage == nil)
        #expect(harness.model.selectedChatID == ChatID(1))
    }

    @Test func logoutDuringAccountCheckDoesNotSelectOldChat() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        harness.fake.hold(.getMe)
        harness.model.openNotification(try target(chat: "2", account: "999"))
        #expect(await eventually { harness.fake.isWaiting(on: .getMe) })
        await harness.model.logOut()
        #expect(await eventually { harness.model.authState == .needsPhoneNumber })
        harness.fake.release(.getMe)
        try await settle()
        #expect(harness.model.currentChat == nil)
        #expect(harness.model.selectedChatID == ChatID(1))
    }

    private func target(chat: String, account: String? = nil) throws -> TelegramNotification {
        var payload: [AnyHashable: Any] = ["from_id": chat]
        payload["user_id"] = account
        return try #require(TelegramNotification(userInfo: payload))
    }
}
