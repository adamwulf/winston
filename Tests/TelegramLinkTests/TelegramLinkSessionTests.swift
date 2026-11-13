import CoreGraphics
import Foundation
import ImageIO
import Testing
import TelegramLink
import TelegramLinkTestSupport
import UniformTypeIdentifiers

// TDLibKit isn't imported here: it has its own `ChatEvent`, `Message` and `File`. The builders in
// TelegramLinkTestSupport make the TDLibKit values these tests hand to the fake.
// Tests that must name a TDLibKit type are in TelegramLinkSessionTDLibTests.swift.

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

    /// Returns once the link has finished the work it is doing now, such as the rest of the
    /// update whose state or event was just read. The link is an actor, so a call to it waits
    /// for that work; marking no messages read is such a call, and does nothing else.
    func roundTrip() async throws {
        try await link.markRead([], in: ChatID(0))
    }
}

/// An error that isn't TDLib's, with a description of its own.
private struct DiskFull: LocalizedError {
    var errorDescription: String? { "The disk is full." }
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

    @Test func startingTwiceCreatesOneClient() async throws {
        let session = Session()
        try await session.startAndLogIn()

        try await session.link.start()

        #expect(session.fake.clientCount == 1)
        #expect(session.fake.requests.filter { $0 == .execute("setLogVerbosityLevel") }.count == 1)
    }

    @Test func appsLinkNeedsStartBeforeAnyRequest() async throws {
        let link = TelegramLink(config: .testing)

        await #expect(throws: TelegramLinkError.notStarted) {
            try await link.sendText("hello", to: ChatID(5))
        }
    }

    @Test func everyRequestBeforeStartThrowsNotStarted() async throws {
        let session = Session()
        let link = session.link
        let chat = ChatID(5)

        await #expect(throws: TelegramLinkError.notStarted) { try await link.submitPhoneNumber("+15551234567") }
        await #expect(throws: TelegramLinkError.notStarted) { try await link.submitCode("12345") }
        await #expect(throws: TelegramLinkError.notStarted) { try await link.submitPassword("hunter2") }
        await #expect(throws: TelegramLinkError.notStarted) { try await link.logOut() }
        await #expect(throws: TelegramLinkError.notStarted) { try await link.botChats() }
        await #expect(throws: TelegramLinkError.notStarted) { try await link.history(in: chat, limit: 10) }
        await #expect(throws: TelegramLinkError.notStarted) { try await link.sendText("hello", to: chat) }
        await #expect(throws: TelegramLinkError.notStarted) {
            try await link.sendPhoto(fileURL: URL(filePath: "/tmp/winston-tests/none.png"), caption: nil, to: chat)
        }
        await #expect(throws: TelegramLinkError.notStarted) {
            try await link.toggleReaction("👍", on: MessageID(1), in: chat)
        }
        await #expect(throws: TelegramLinkError.notStarted) {
            try await link.downloadFile(FileRef(id: 1, localPath: nil))
        }
        await #expect(throws: TelegramLinkError.notStarted) { try await link.markRead([MessageID(1)], in: chat) }
        #expect(session.fake.clientCount == 0)
        #expect(session.fake.requests.isEmpty)
    }

    @Test func tdlibErrorIsThrownAsTelegramLinkError() async throws {
        let session = Session(fake: FakeTDLib(isLoggedIn: false))
        session.fake.fail(.checkAuthenticationCode, code: 400, message: "PHONE_CODE_INVALID")
        try await session.link.start()
        #expect(await session.nextState() == .starting)
        #expect(await session.nextState() == .needsPhoneNumber)
        try await session.link.submitPhoneNumber("+15551234567")
        #expect(await session.nextState() == .needsCode)

        await #expect(throws: TelegramLinkError.tdlib(code: 400, message: "PHONE_CODE_INVALID")) {
            try await session.link.submitCode("00000")
        }
        #expect(session.fake.requests.last == .checkAuthenticationCode("00000"))
    }

    @Test func errorThatIsNotTDLibsIsThrownUnchanged() async throws {
        let session = Session()
        session.fake.fail(.logOut, with: URLError(.timedOut))
        try await session.startAndLogIn()

        let error = await #expect(throws: URLError.self) {
            try await session.link.logOut()
        }

        #expect(error?.code == .timedOut)
    }

    @Test func startStillReachesReadyWhenLoweringTDLibLoggingFails() async throws {
        let session = Session()
        session.fake.fail(.execute, code: 400, message: "Unknown log verbosity level")

        try await session.startAndLogIn()

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

    @Test func closeForTerminationClosesTheClientWithoutStartingAFreshOne() async throws {
        let session = Session()
        try await session.startAndLogIn()

        await session.link.closeForTermination()

        #expect(await session.nextState() == .loggingOut)
        #expect(await session.nextState() == .closed)
        try await session.roundTrip()
        #expect(session.fake.clientCount == 1)
    }

    @Test func setupFailureIsPublishedWithTDLibsMessage() async throws {
        let session = Session()
        session.fake.fail(.setTdlibParameters, code: 400, message: "Valid api_id must be provided")

        try await session.link.start()

        #expect(await session.nextState() == .starting)
        #expect(await session.nextState() == .unsupported("setTdlibParameters failed: Valid api_id must be provided"))
    }

    @Test func setupFailureThatIsNotTDLibsIsPublishedWithItsDescription() async throws {
        let session = Session()
        session.fake.fail(.setTdlibParameters, with: DiskFull())

        try await session.link.start()

        #expect(await session.nextState() == .starting)
        #expect(await session.nextState() == .unsupported("setTdlibParameters failed: The disk is full."))
    }
}

/// The bot chats in the main chat list.
@Suite(.timeLimit(.minutes(1)))
struct ChatListTests {
    @Test func botChatsStillListsChatsWhenTheChatListIsAlreadyLoaded() async throws {
        let session = Session()
        session.fake.addBotChat(id: 5, title: "Home", username: "home_bot")
        // TDLib answers 404 when every chat in the list is already loaded.
        session.fake.fail(.loadChats, code: 404, message: "Not Found")
        try await session.startAndLogIn()

        let bots = try await session.link.botChats()

        #expect(bots == [BotChat(id: ChatID(5), title: "Home", username: "home_bot")])
        #expect(session.fake.requests.suffix(4) == [
            .loadChats(limit: 100),
            .getChats(limit: 100),
            .getChat(5),
            .getUser(5),
        ])
    }

    @Test func botChatsRethrowsOtherChatListErrors() async throws {
        let session = Session()
        session.fake.addBotChat(id: 5, title: "Home", username: "home_bot")
        session.fake.fail(.loadChats, code: 500, message: "Internal Server Error")
        try await session.startAndLogIn()

        await #expect(throws: TelegramLinkError.tdlib(code: 500, message: "Internal Server Error")) {
            try await session.link.botChats()
        }
        #expect(session.fake.requests.last == .loadChats(limit: 100))
    }
}

/// A chat's history, which TDLib hands out a page at a time.
@Suite(.timeLimit(.minutes(1)))
struct HistoryTests {
    @Test func historyPagesBackwardsAndReturnsTheNewestMessagesOldestFirst() async throws {
        let session = Session()
        session.fake.addHistory((1...7).map { textMessage(id: Int64($0), chatID: 5, "message \($0)") })
        session.fake.historyPageSize = 3
        try await session.startAndLogIn()
        let loginRequests = session.fake.requests.count

        let messages = try await session.link.history(in: ChatID(5), limit: 5)

        #expect(messages.map(\.id) == [MessageID(3), MessageID(4), MessageID(5), MessageID(6), MessageID(7)])
        #expect(messages.map(\.text) == ["message 3", "message 4", "message 5", "message 6", "message 7"])
        #expect(Array(session.fake.requests.dropFirst(loginRequests)) == [
            .getChatHistory(chatID: 5, fromMessageID: 0, limit: 5),
            .getChatHistory(chatID: 5, fromMessageID: 5, limit: 2),
        ])
    }

    @Test func historyStopsWhenThereAreNoOlderMessages() async throws {
        let session = Session()
        session.fake.addHistory([
            textMessage(id: 1, chatID: 5, "first"),
            textMessage(id: 2, chatID: 5, "second"),
        ])
        try await session.startAndLogIn()
        let loginRequests = session.fake.requests.count

        let messages = try await session.link.history(in: ChatID(5), limit: 50)

        #expect(messages.map(\.text) == ["first", "second"])
        #expect(Array(session.fake.requests.dropFirst(loginRequests)) == [
            .getChatHistory(chatID: 5, fromMessageID: 0, limit: 50),
            .getChatHistory(chatID: 5, fromMessageID: 1, limit: 48),
        ])
    }

    @Test func historyOfNoMessagesAsksTDLibForNothing() async throws {
        let session = Session()
        session.fake.addHistory([textMessage(id: 1, chatID: 5, "first")])
        try await session.startAndLogIn()
        let loginRequests = session.fake.requests.count

        let messages = try await session.link.history(in: ChatID(5), limit: 0)

        #expect(messages.isEmpty)
        #expect(session.fake.requests.count == loginRequests)
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

    @Test func rejectedSendIsReportedUnderTheTemporaryID() async throws {
        let session = Session()
        session.fake.addBotChat(id: 5, title: "Home", username: "home_bot")
        try await session.startAndLogIn()
        try await session.link.sendText("/compact", to: ChatID(5))
        guard case .newMessage(let pending) = await session.nextEvent() else {
            Issue.record("expected the pending message as a new message")
            return
        }

        session.fake.failSend(of: pending.id.rawValue, in: 5, message: "PEER_ID_INVALID")

        #expect(await session.nextEvent() == .sendFailed(chat: ChatID(5), message: pending.id, error: "PEER_ID_INVALID"))
    }

    @Test func sendPhotoPassesTheFileTheCaptionAndThePixelSize() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = try writePNG(width: 40, height: 30, to: folder.appending(path: "square.png"))
        let session = Session()
        session.fake.addBotChat(id: 5, title: "Home", username: "home_bot")
        try await session.startAndLogIn()

        try await session.link.sendPhoto(fileURL: photo, caption: "a red rectangle", to: ChatID(5))

        let path = photo.path(percentEncoded: false)
        #expect(session.fake.requests.last == .sendPhoto(
            chatID: 5,
            path: path,
            caption: "a red rectangle",
            width: 40,
            height: 30
        ))
        guard case .newMessage(let pending) = await session.nextEvent() else {
            Issue.record("expected the pending photo as a new message")
            return
        }
        #expect(pending.text == "a red rectangle")
        #expect(pending.attachment == .photo(FileRef(id: 1, localPath: path), width: 40, height: 30))
        #expect(pending.sendState == .pending)
    }

    @Test func sendPhotoWithoutCaptionSendsNoCaption() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = try writePNG(width: 40, height: 30, to: folder.appending(path: "square.png"))
        let session = Session()
        session.fake.addBotChat(id: 5, title: "Home", username: "home_bot")
        try await session.startAndLogIn()

        try await session.link.sendPhoto(fileURL: photo, caption: nil, to: ChatID(5))

        #expect(session.fake.requests.last == .sendPhoto(
            chatID: 5,
            path: photo.path(percentEncoded: false),
            caption: nil,
            width: 40,
            height: 30
        ))
    }

    @Test func sendPhotoOfAFileThatIsNotAnImageSendsZeroSize() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let notes = folder.appending(path: "notes.txt")
        try Data("not an image".utf8).write(to: notes)
        let session = Session()
        session.fake.addBotChat(id: 5, title: "Home", username: "home_bot")
        try await session.startAndLogIn()

        try await session.link.sendPhoto(fileURL: notes, caption: "notes", to: ChatID(5))

        #expect(session.fake.requests.last == .sendPhoto(
            chatID: 5,
            path: notes.path(percentEncoded: false),
            caption: "notes",
            width: 0,
            height: 0
        ))
    }
}

/// Emoji reactions on a message.
@Suite(.timeLimit(.minutes(1)))
struct ReactionTests {
    @Test func toggleReactionAddsAdamsReactionThenRemovesIt() async throws {
        let session = Session()
        session.fake.addHistory([textMessage(id: 10, chatID: 5, "Done.")])
        try await session.startAndLogIn()
        let loginRequests = session.fake.requests.count

        try await session.link.toggleReaction("👍", on: MessageID(10), in: ChatID(5))

        #expect(await session.nextEvent() == .reactionsChanged(
            chat: ChatID(5),
            message: MessageID(10),
            reactions: [Reaction(emoji: "👍", count: 1, isChosen: true)]
        ))

        try await session.link.toggleReaction("👍", on: MessageID(10), in: ChatID(5))

        #expect(await session.nextEvent() == .reactionsChanged(chat: ChatID(5), message: MessageID(10), reactions: []))
        #expect(Array(session.fake.requests.dropFirst(loginRequests)) == [
            .getMessage(chatID: 5, messageID: 10),
            .addReaction(chatID: 5, messageID: 10, emoji: "👍"),
            .getMessage(chatID: 5, messageID: 10),
            .removeReaction(chatID: 5, messageID: 10, emoji: "👍"),
        ])
    }

    @Test func toggleReactionOnAMissingMessageThrows() async throws {
        let session = Session()
        try await session.startAndLogIn()

        await #expect(throws: TelegramLinkError.tdlib(code: 404, message: "Not Found")) {
            try await session.link.toggleReaction("👍", on: MessageID(99), in: ChatID(5))
        }
        #expect(session.fake.requests.last == .getMessage(chatID: 5, messageID: 99))
    }
}

/// Downloading files, and marking messages read.
@Suite(.timeLimit(.minutes(1)))
struct FileAndReadTests {
    @Test func downloadFileReturnsTheLocalURLOfTheFinishedDownload() async throws {
        let session = Session()
        session.fake.setFile(file(id: 7, downloadedPath: "/tmp/winston-tests/files/photo.jpg"))
        try await session.startAndLogIn()

        let url = try await session.link.downloadFile(FileRef(id: 7, localPath: nil))

        #expect(url == URL(filePath: "/tmp/winston-tests/files/photo.jpg"))
        #expect(session.fake.requests.last == .downloadFile(fileID: 7))
    }

    @Test func downloadFileThrowsWhenTheDownloadDidNotFinish() async throws {
        let session = Session()
        session.fake.setFile(file(id: 8))
        try await session.startAndLogIn()

        await #expect(throws: TelegramLinkError.tdlib(code: 0, message: "The download didn't finish.")) {
            try await session.link.downloadFile(FileRef(id: 8, localPath: nil))
        }
        #expect(session.fake.requests.last == .downloadFile(fileID: 8))
    }

    @Test func markReadViewsTheMessagesAndForcesThemRead() async throws {
        let session = Session()
        try await session.startAndLogIn()

        try await session.link.markRead([MessageID(3), MessageID(4)], in: ChatID(5))

        #expect(session.fake.requests.last == .viewMessages(chatID: 5, messageIDs: [3, 4], forceRead: true))
    }

    @Test func markReadWithNoMessagesSendsNothing() async throws {
        let session = Session()
        try await session.startAndLogIn()
        let loginRequests = session.fake.requests.count

        try await session.link.markRead([], in: ChatID(5))

        #expect(session.fake.requests.count == loginRequests)
    }
}

/// The updates TDLib sends on its own, turned into events.
@Suite(.timeLimit(.minutes(1)))
struct UpdateTests {
    @Test func incomingMessageArrivesAsNewMessage() async throws {
        let session = Session()
        try await session.startAndLogIn()

        session.fake.receive(textMessage(id: 11, chatID: 5, date: 1_700_000_000, "Build finished."))

        #expect(await session.nextEvent() == .newMessage(ChatMessage(
            id: MessageID(11),
            chatID: ChatID(5),
            isOutgoing: false,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            text: "Build finished."
        )))
    }

    @Test func updateTDLibKitCannotDecodeIsSkipped() async throws {
        let session = Session()
        try await session.startAndLogIn()

        session.fake.sendRaw(Data(#"{"@type":"updateFromTheFuture","value":1}"#.utf8))
        session.fake.receive(textMessage(id: 11, chatID: 5, "Still here."))

        // The message is the next event: the link skipped the update and kept going.
        guard case .newMessage(let message) = await session.nextEvent() else {
            Issue.record("expected the message that followed the update")
            return
        }
        #expect(message.text == "Still here.")
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

    @Test func cancelActionEndsTypingAtOnce() async throws {
        // The timeout is a minute, so only the cancel can end typing within the test.
        let session = Session()
        try await session.startAndLogIn()
        session.fake.setTyping(true, in: 5)
        #expect(await session.nextEvent() == .typing(chat: ChatID(5), isTyping: true))

        session.fake.setTyping(false, in: 5)

        #expect(await session.nextEvent() == .typing(chat: ChatID(5), isTyping: false))
    }

    @Test func anotherTypingActionRestartsTheTimeout() async throws {
        let session = Session(typingTimeout: .milliseconds(50))
        try await session.startAndLogIn()
        let clock = ContinuousClock()
        session.fake.setTyping(true, in: 5)
        let refreshed = clock.now

        session.fake.setTyping(true, in: 5)

        #expect(await session.nextEvent() == .typing(chat: ChatID(5), isTyping: true))
        #expect(await session.nextEvent() == .typing(chat: ChatID(5), isTyping: true))
        #expect(await session.nextEvent() == .typing(chat: ChatID(5), isTyping: false))
        // Typing lasted the full timeout from the second action.
        #expect(clock.now - refreshed >= .milliseconds(50))
        // Another chat's typing, ended by its own timeout, comes next: no second "stopped"
        // for chat 5 arrived before it.
        session.fake.setTyping(true, in: 6)
        #expect(await session.nextEvent() == .typing(chat: ChatID(6), isTyping: true))
        #expect(await session.nextEvent() == .typing(chat: ChatID(6), isTyping: false))
    }
}

// MARK: - Files on disk

/// A new, empty folder in the temporary directory.
private func makeTemporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appending(path: "TelegramLinkTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Writes a solid red PNG of `width` by `height` pixels to `url`, and returns `url`.
private func writePNG(width: Int, height: Int, to url: URL) throws -> URL {
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    return url
}
