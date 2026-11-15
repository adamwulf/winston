import Foundation
import Testing
import TelegramLink
import TelegramLinkTestSupport
import VoiceLoopTestSupport
import WinstonCore

/// Coming back to the foreground after iOS suspended the app, and catching up on the messages
/// that arrived meanwhile. The tests call `appDidBecomeActive()` and `appDidLeaveForeground()`
/// in place of the system's notifications, which would reach every test's model.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ForegroundTests {
    /// The values the model has set TDLib's `online` option to so far, in order.
    private func onlineValues(_ fake: FakeTDLib) -> [Bool] {
        fake.requests.compactMap { request in
            guard case .setOption(let name, let value) = request, name == "online" else { return nil }
            return value
        }
    }

    @Test func comingToTheForegroundSetsTDLibOnlineAndLeavingItSetsItOffline() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        // Logged in before the app was active.
        #expect(await eventually { onlineValues(harness.fake) == [false] })

        model.appDidBecomeActive()
        #expect(await eventually { onlineValues(harness.fake) == [false, true] })

        model.appDidLeaveForeground()
        #expect(await eventually { onlineValues(harness.fake) == [false, true, false] })
    }

    @Test func theForegroundBeforeLoginReachesTDLibOnceLoggedIn() async throws {
        let harness = Harness(fake: FakeTDLib(isLoggedIn: false))
        let model = harness.model
        model.start()
        model.appDidBecomeActive()
        #expect(await eventually { model.authState == .needsPhoneNumber })
        try await settle()
        // TDLib's account status needs an account.
        #expect(onlineValues(harness.fake).isEmpty)

        try await model.submitPhoneNumber("+15551234567")
        try await model.submitCode("12345")

        #expect(await eventually { onlineValues(harness.fake) == [true] })
    }

    @Test func quickComingsAndGoingsReachTDLibInOrder() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        #expect(await eventually { onlineValues(harness.fake) == [false] })
        harness.fake.hold(.setOption)

        model.appDidBecomeActive()
        model.appDidLeaveForeground()
        model.appDidBecomeActive()

        #expect(await eventually { harness.fake.isWaiting(on: .setOption) })
        try await settle()
        // The later ones wait for the first.
        #expect(onlineValues(harness.fake) == [false, true])
        harness.fake.release(.setOption)
        #expect(await eventually { onlineValues(harness.fake) == [false, true, false, true] })
    }

    @Test func failingToSetTheStatusShowsNoErrorAndTheNextOneStillGoes() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        #expect(await eventually { onlineValues(harness.fake) == [false] })
        harness.fake.fail(.setOption, code: 500, message: "Internal Server Error")

        model.appDidBecomeActive()
        #expect(await eventually { onlineValues(harness.fake) == [false, true] })
        harness.fake.succeed(.setOption)
        model.appDidLeaveForeground()

        #expect(await eventually { onlineValues(harness.fake) == [false, true, false] })
        #expect(model.errorMessage == nil)
    }

    @Test func aMessageTDLibCatchesUpBeforeTheBotChatsLoadShowsOnceTheyDo() async throws {
        let harness = Harness.withTwoBots()
        harness.fake.hold(.getChats)
        let model = harness.model
        model.start()
        #expect(await eventually { harness.fake.isWaiting(on: .getChats) })

        // At launch TDLib fetches what came while the app was gone, before the model knows
        // which chats are bot chats.
        harness.fake.receive(textMessage(id: 12, chatID: 1, "Both jobs are done."))
        try await settle()
        harness.fake.release(.getChats)

        #expect(await eventually { model.messages[ChatID(2)] != nil })
        #expect(model.messages[ChatID(1)]?.map(\.id) == [MessageID(10), MessageID(11), MessageID(12)])
    }

    @Test func aMessageTDLibDeliversTwiceShowsOnce() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        model.appDidBecomeActive()
        let message = textMessage(id: 12, chatID: 1, "Both jobs are done.")

        harness.fake.receive(message)
        harness.fake.receive(message)
        harness.fake.receive(textMessage(id: 13, chatID: 1, "Deployed."))

        // Events arrive in order, so once the last shows, the ones before it were handled.
        #expect(await eventually { model.currentMessages.last?.id == MessageID(13) })
        #expect(model.currentMessages.map(\.id) == [MessageID(10), MessageID(11), MessageID(12), MessageID(13)])
    }
}
