import Foundation
import Testing
import TelegramLink
import TelegramLinkTestSupport

// TDLibKit isn't imported here: it has its own `ChatEvent`, `Message` and `File`. The builders in
// TelegramLinkTestSupport make the TDLibKit values these tests hand to the fake.

/// A `TelegramLink` over a fake TDLib, with its two streams read in order.
final class Session {
    let fake: FakeTDLib
    let link: TelegramLink
    private var states: AsyncStream<AuthState>.Iterator
    private var events: AsyncStream<ChatEvent>.Iterator

    init(fake: FakeTDLib = FakeTDLib(), typingTimeout: Duration = .seconds(60)) {
        self.fake = fake
        link = fake.makeLink(typingTimeout: typingTimeout)
        states = link.authStates.makeAsyncIterator()
        events = link.events.makeAsyncIterator()
    }

    /// The next login state the link reports. Waits for it.
    func nextState() async -> AuthState? {
        var iterator = states
        defer { states = iterator }
        return await iterator.next()
    }

    /// The next chat event the link reports. Waits for it.
    func nextEvent() async -> ChatEvent? {
        var iterator = events
        defer { events = iterator }
        return await iterator.next()
    }

    /// Starts the link and reads its states up to `.ready`, for an account that is logged in.
    func startAndLogIn() async throws {
        try await link.start()
        #expect(await nextState() == .starting)
        #expect(await nextState() == .ready)
    }
}

/// The link's login state machine, driven by the updates TDLib sends.
@Suite(.timeLimit(.minutes(1)))
struct LoginTests {
    @Test func startLowersTDLibLoggingAppliesTheConfigAndReachesReady() async throws {
        let session = Session()

        try await session.link.start()

        #expect(await session.nextState() == .starting)
        #expect(await session.nextState() == .ready)
        #expect(session.fake.requests == [
            .execute("setLogVerbosityLevel"),
            .setTdlibParameters(
                apiID: 42,
                apiHash: "hash",
                databaseDirectory: "/tmp/winston-tests/db/",
                filesDirectory: "/tmp/winston-tests/files/"
            ),
        ])
    }

    @Test func loggedOutAccountWalksPhoneNumberCodeAndPassword() async throws {
        let session = Session(fake: FakeTDLib(isLoggedIn: false, passwordHint: "first dog"))
        try await session.link.start()
        #expect(await session.nextState() == .starting)
        #expect(await session.nextState() == .needsPhoneNumber)

        try await session.link.submitPhoneNumber("+15551234567")
        #expect(await session.nextState() == .needsCode)

        try await session.link.submitCode("12345")
        #expect(await session.nextState() == .needsPassword(hint: "first dog"))

        try await session.link.submitPassword("hunter2")
        #expect(await session.nextState() == .ready)

        #expect(session.fake.requests.suffix(3) == [
            .setAuthenticationPhoneNumber("+15551234567"),
            .checkAuthenticationCode("12345"),
            .checkAuthenticationPassword("hunter2"),
        ])
    }

    @Test func logOutClosesTheClientAndStartsLoginAgainOnAFreshOne() async throws {
        let session = Session()
        try await session.startAndLogIn()

        try await session.link.logOut()

        #expect(await session.nextState() == .loggingOut)
        #expect(await session.nextState() == .closed)
        #expect(await session.nextState() == .starting)
        #expect(await session.nextState() == .needsPhoneNumber)
        #expect(session.fake.clientCount == 2)
    }
}

/// Sending, and the events that follow a sent message.
@Suite(.timeLimit(.minutes(1)))
struct SendingTests {
    @Test func sentTextIsPendingUntilTheServerAcceptsIt() async throws {
        let session = Session()
        session.fake.addBotChat(id: 5, title: "Home", username: "home_bot")
        try await session.startAndLogIn()

        try await session.link.sendText("/compact", to: ChatID(5))

        #expect(session.fake.requests.last == .sendText(chatID: 5, text: "/compact"))
        guard case .newMessage(let pending) = await session.nextEvent() else {
            Issue.record("expected the pending message as a new message")
            return
        }
        #expect(pending.chatID == ChatID(5))
        #expect(pending.isOutgoing)
        #expect(pending.text == "/compact")
        #expect(pending.sendState == .pending)

        session.fake.confirmSend(of: pending.id.rawValue, in: 5, as: 77)

        guard case .sendSucceeded(let chat, let oldID, let sent) = await session.nextEvent() else {
            Issue.record("expected the send to succeed")
            return
        }
        #expect(chat == ChatID(5))
        #expect(oldID == pending.id)
        #expect(sent.id == MessageID(77))
        #expect(sent.text == "/compact")
        #expect(sent.sendState == .sent)
    }
}

/// "Typing" from TDLib's chat actions, which expire unless refreshed.
@Suite(.timeLimit(.minutes(1)))
struct TypingTests {
    @Test func typingEndsByItselfWhenTheActionIsNotRefreshed() async throws {
        let session = Session(typingTimeout: .milliseconds(50))
        try await session.startAndLogIn()

        session.fake.setTyping(true, in: 5)

        #expect(await session.nextEvent() == .typing(chat: ChatID(5), isTyping: true))
        #expect(await session.nextEvent() == .typing(chat: ChatID(5), isTyping: false))
    }
}
