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
}

/// Voice mode: what is heard goes to the bot, and the bot's replies are spoken.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct VoiceModeTests {
    @Test func whatIsSaidIsSentToTheCurrentChatMarkedAsSpoken() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        model.pauseThreshold = 0.05

        await model.setVoiceMode(true)
        #expect(model.isVoiceMode)
        #expect(model.voiceLoop.state == .listening(partial: ""))
        harness.bed.recognizer.hear("Mark that read.", over: 0...1, isFinal: true, alternatives: ["Mark that red."])

        #expect(await eventually {
            harness.fake.requests.last == .sendText(chatID: 1, text: "🎙️ Mark that read. (alt: Mark that red.)")
        })
    }

    @Test func inVoiceModeAReplyInTheCurrentChatIsSpokenAndOneElsewhereIsNot() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        await model.setVoiceMode(true)

        // The other chat's reply is shown but not read out.
        harness.fake.receive(textMessage(id: 21, chatID: 2, "Starting the coordinator."))
        #expect(await eventually { model.messages[ChatID(2)]?.last?.text == "Starting the coordinator." })
        #expect(model.voiceLoop.state == .listening(partial: ""))
        #expect(harness.bed.audio.playedFrames == 0)

        harness.fake.receive(textMessage(id: 12, chatID: 1, "Done."))
        #expect(await eventually { model.voiceLoop.state == .speaking })
        #expect(await eventually { model.voiceLoop.state == .listening(partial: "") })
        #expect(harness.bed.audio.playedFrames > 0)
    }
}
