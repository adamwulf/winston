import Foundation
@preconcurrency import TDLibKit
import Testing
import TelegramLink
import TelegramLinkTestSupport

// Session tests that build TDLibKit values the builders don't cover, so this file imports
// TDLibKit. Its `ChatEvent` would clash with TelegramLink's, so events here are compared without
// naming the type.

/// Bot chats among the other chats in the main chat list.
@Suite(.timeLimit(.minutes(1)))
struct ChatListFilterTests {
    @Test func botChatsListsOnlyPrivateChatsWithBotsInListOrder() async throws {
        let session = Session()
        session.fake.addBotChat(id: 9, title: "Work", username: "work_bot")
        session.fake.add(
            chat: chat(id: 6, title: "Sam", type: .chatTypePrivate(ChatTypePrivate(userId: 6))),
            user: user(id: 6, type: .userTypeRegular, username: "sam")
        )
        session.fake.add(chat: chat(id: 7, title: "Family", type: .chatTypeBasicGroup(ChatTypeBasicGroup(basicGroupId: 70))))
        session.fake.addBotChat(id: 5, title: "Home", username: "home_bot")
        try await session.startAndLogIn()
        let loginRequests = session.fake.requests.count

        let bots = try await session.link.botChats()

        #expect(bots == [
            BotChat(id: ChatID(9), title: "Work", username: "work_bot"),
            BotChat(id: ChatID(5), title: "Home", username: "home_bot"),
        ])
        // A group chat has no one user, so the link doesn't ask for one.
        #expect(Array(session.fake.requests.dropFirst(loginRequests)) == [
            .loadChats(limit: 100),
            .getChats(limit: 100),
            .getChat(9),
            .getUser(9),
            .getChat(6),
            .getUser(6),
            .getChat(7),
            .getChat(5),
            .getUser(5),
        ])
    }
}

/// Login states and updates the app doesn't act on.
@Suite(.timeLimit(.minutes(1)))
struct UnhandledUpdateTests {
    @Test func loginStateTheAppDoesNotHandleIsPublishedAsUnsupported() async throws {
        let session = Session()
        try await session.startAndLogIn()

        session.fake.send(.updateAuthorizationState(UpdateAuthorizationState(
            authorizationState: .authorizationStateWaitEmailAddress(
                AuthorizationStateWaitEmailAddress(allowAppleId: false, allowGoogleId: false)
            )
        )))

        #expect(await session.nextState() == .unsupported("authorizationStateWaitEmailAddress"))
    }

    @Test func updateTheAppDoesNotUseIsSkipped() async throws {
        let session = Session()
        try await session.startAndLogIn()

        session.fake.send(.updateChatTitle(UpdateChatTitle(chatId: 5, title: "Renamed")))
        session.fake.receive(textMessage(id: 11, chatID: 5, "Still here."))

        // The message is the next event: the title change published nothing.
        guard case .newMessage(let message) = await session.nextEvent() else {
            Issue.record("expected the message that followed the update")
            return
        }
        #expect(message.text == "Still here.")
    }

    @Test func otherChatActionsNeitherStartNorEndTyping() async throws {
        // The timeout is a minute, so typing can't end by itself within the test.
        let session = Session()
        try await session.startAndLogIn()
        session.fake.setTyping(true, in: 5)
        #expect(await session.nextEvent() == .typing(chat: ChatID(5), isTyping: true))

        session.fake.send(.updateChatAction(UpdateChatAction(
            action: .chatActionChoosingSticker,
            chatId: 5,
            senderId: .messageSenderUser(MessageSenderUser(userId: 5)),
            topicId: nil
        )))
        session.fake.receive(textMessage(id: 11, chatID: 5, "Here you go."))

        // The message is the next event: choosing a sticker neither started nor ended typing.
        guard case .newMessage(let message) = await session.nextEvent() else {
            Issue.record("expected the message that followed the chat action")
            return
        }
        #expect(message.text == "Here you go.")
    }
}

/// Reactions that other people added first.
@Suite(.timeLimit(.minutes(1)))
struct SharedReactionTests {
    @Test func toggleReactionAddsAdamsWhenOnlyOthersReactedWithThatEmoji() async throws {
        let thumbsUp = ReactionType.reactionTypeEmoji(ReactionTypeEmoji(emoji: "👍"))
        let session = Session()
        session.fake.addHistory([textMessage(
            id: 10,
            chatID: 5,
            "Done.",
            interactionInfo: interactionInfo([messageReaction(thumbsUp, count: 2, isChosen: false)])
        )])
        try await session.startAndLogIn()

        try await session.link.toggleReaction("👍", on: MessageID(10), in: ChatID(5))

        #expect(session.fake.requests.last == .addReaction(chatID: 5, messageID: 10, emoji: "👍"))
        #expect(await session.nextEvent() == .reactionsChanged(
            chat: ChatID(5),
            message: MessageID(10),
            reactions: [Reaction(emoji: "👍", count: 3, isChosen: true)]
        ))
    }
}
