import Foundation
import Testing
import TelegramLink
import TelegramLinkTestSupport
import VoiceLoop
import VoiceLoopTestSupport
import WinstonCore

/// What TDLib reports as it happens: new messages, typing, and how sent messages fare.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct EventTests {
    @Test func anIncomingMessageAppearsInItsChatAndEndsThatChatsTyping() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        harness.fake.setTyping(true, in: 1)
        harness.fake.setTyping(true, in: 2)
        #expect(await eventually { model.typingChats == [ChatID(1), ChatID(2)] })

        harness.fake.receive(textMessage(id: 12, chatID: 1, "Both jobs are done."))

        #expect(await eventually { model.currentMessages.last?.text == "Both jobs are done." })
        #expect(model.latestIncomingMessage?.id == MessageID(12))
        #expect(!model.isBotTyping)
        // Laptop's bot is still typing.
        #expect(model.typingChats == [ChatID(2)])
        #expect(model.messages[ChatID(2)]?.map(\.text) == ["The coordinator is offline."])
    }

    @Test func eventsForAChatThatIsNotABotChatAreIgnored() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        // Chat 9 is with a person. A message sent there from another device is confirmed.
        harness.fake.addHistory([textMessage(id: 60, chatID: 9, isOutgoing: true, "On my way.")])

        harness.fake.receive(textMessage(id: 61, chatID: 9, "See you soon."))
        harness.fake.setTyping(true, in: 9)
        harness.fake.confirmSend(of: 60, in: 9, as: 62)
        // Events arrive in order, so once this one shows, the ones before it were handled.
        harness.fake.receive(textMessage(id: 12, chatID: 1, "Both jobs are done."))

        #expect(await eventually { model.currentMessages.last?.text == "Both jobs are done." })
        #expect(model.messages[ChatID(9)] == nil)
        #expect(Set(model.messages.keys) == [ChatID(1), ChatID(2)])
        #expect(model.typingChats.isEmpty)
    }

    @Test func typingShowsForTheChosenChatOnly() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model

        harness.fake.setTyping(true, in: 2)
        #expect(await eventually { model.typingChats == [ChatID(2)] })
        #expect(!model.isBotTyping)

        harness.fake.setTyping(true, in: 1)
        #expect(await eventually { model.isBotTyping })

        harness.fake.setTyping(false, in: 1)
        #expect(await eventually { !model.isBotTyping })
        #expect(model.typingChats == [ChatID(2)])
    }

    @Test func aSentMessageIsPendingThenTakesItsFinalIDInPlaceOrShowsWhyItFailed() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model

        #expect(await model.sendText("Run the tests."))
        #expect(await model.sendText("Then deploy."))

        #expect(harness.fake.requests.suffix(2) == [
            .sendText(chatID: 1, text: "Run the tests."),
            .sendText(chatID: 1, text: "Then deploy."),
        ])
        #expect(await eventually { model.currentMessages.count == 4 })
        let pending = Array(model.currentMessages.suffix(2))
        #expect(pending.map(\.text) == ["Run the tests.", "Then deploy."])
        #expect(pending.allSatisfy { $0.isOutgoing && $0.sendState == .pending })

        harness.fake.confirmSend(of: pending[0].id.rawValue, in: 1, as: 13)

        #expect(await eventually { model.currentMessages.contains { $0.id == MessageID(13) } })
        #expect(model.currentMessages.map(\.id) == [MessageID(10), MessageID(11), MessageID(13), pending[1].id])
        #expect(model.currentMessages.map(\.sendState) == [.sent, .sent, .sent, .pending])
        #expect(model.currentMessages[2].text == "Run the tests.")

        harness.fake.failSend(of: pending[1].id.rawValue, in: 1, message: "PEER_ID_INVALID")

        #expect(await eventually { model.currentMessages.last?.sendState == .failed("PEER_ID_INVALID") })
        #expect(model.currentMessages.map(\.id) == [MessageID(10), MessageID(11), MessageID(13), pending[1].id])
    }

    @Test func whenTDLibRefusesToSendTheErrorIsShown() async throws {
        let harness = Harness.withTwoBots()
        harness.fake.fail(.sendMessage, code: 403, message: "CHAT_WRITE_FORBIDDEN")
        #expect(await harness.startAndLoadChats())
        let model = harness.model

        #expect(await model.sendText("Run the tests.") == false)

        #expect(harness.fake.requests.last == .sendText(chatID: 1, text: "Run the tests."))
        #expect(model.errorMessage == "CHAT_WRITE_FORBIDDEN")
        #expect(model.currentMessages.map(\.text) == ["What's on the build server?", "Two jobs are queued."])
    }

    @Test func aReactionChangeForAMessageTheModelDoesNotHaveIsIgnored() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        // An older message in Home that wasn't loaded, and one in a chat with a person.
        harness.fake.addHistory([
            textMessage(id: 5, chatID: 1, "An old reply."),
            textMessage(id: 70, chatID: 9, "See you soon."),
        ])
        let date = Date(timeIntervalSince1970: 0)

        await model.toggleThumbsUp(on: ChatMessage(id: MessageID(5), chatID: ChatID(1), isOutgoing: false, date: date, text: "An old reply."))
        await model.toggleThumbsUp(on: ChatMessage(id: MessageID(70), chatID: ChatID(9), isOutgoing: false, date: date, text: "See you soon."))
        harness.fake.receive(textMessage(id: 12, chatID: 1, "Both jobs are done."))

        #expect(harness.fake.requests.contains(.addReaction(chatID: 1, messageID: 5, emoji: "👍")))
        #expect(harness.fake.requests.contains(.addReaction(chatID: 9, messageID: 70, emoji: "👍")))
        #expect(await eventually { model.currentMessages.last?.text == "Both jobs are done." })
        #expect(model.currentMessages.map(\.id) == [MessageID(10), MessageID(11), MessageID(12)])
        #expect(model.currentMessages.allSatisfy { $0.reactions.isEmpty })
        #expect(model.messages[ChatID(9)] == nil)
        #expect(model.errorMessage == nil)
    }
}
