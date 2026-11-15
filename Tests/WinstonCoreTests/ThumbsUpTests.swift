import Foundation
import Testing
import TelegramLink
import WinstonCore

@Suite struct ThumbsUpTests {
    private func message(reactions: [Reaction]) -> ChatMessage {
        ChatMessage(
            id: MessageID(1),
            chatID: ChatID(1),
            isOutgoing: false,
            date: Date(timeIntervalSince1970: 0),
            text: "Done.",
            reactions: reactions
        )
    }

    @Test func onlyAdamsOwnThumbsUpCounts() {
        #expect(message(reactions: [Reaction(emoji: "👍", count: 1, isChosen: true)]).hasMyThumbsUp)
        // Someone else's 👍, and Adam's reaction with another emoji.
        #expect(!message(reactions: [Reaction(emoji: "👍", count: 2, isChosen: false)]).hasMyThumbsUp)
        #expect(!message(reactions: [Reaction(emoji: "👀", count: 1, isChosen: true)]).hasMyThumbsUp)
        #expect(!message(reactions: []).hasMyThumbsUp)
        // His 👍 beside the bot's 👀.
        #expect(message(reactions: [
            Reaction(emoji: "👀", count: 1, isChosen: false),
            Reaction(emoji: "👍", count: 1, isChosen: true),
        ]).hasMyThumbsUp)
    }

    @Test func theBotsReactionsAreEveryReactionButAdamsOwn() {
        #expect(message(reactions: [Reaction(emoji: "👍", count: 1, isChosen: false)]).othersReactionCounts == ["👍": 1])
        #expect(message(reactions: [Reaction(emoji: "👍", count: 2, isChosen: true)]).othersReactionCounts == ["👍": 1])
        #expect(message(reactions: [Reaction(emoji: "👍", count: 1, isChosen: true)]).othersReactionCounts == ["👍": 0])
        #expect(message(reactions: [Reaction(emoji: "🎉", count: 1, isChosen: false)]).othersReactionCounts == ["🎉": 1])
        #expect(message(reactions: [
            Reaction(emoji: "👀", count: 1, isChosen: false),
            Reaction(emoji: "👍", count: 1, isChosen: true),
        ]).othersReactionCounts == ["👀": 1, "👍": 0])
        #expect(message(reactions: []).othersReactionCounts == [:])
    }
}
