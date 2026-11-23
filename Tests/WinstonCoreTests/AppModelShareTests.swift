import Foundation
import ShareOutbox
import Testing
import TelegramLink
import TelegramLinkTestSupport
import VoiceLoop
import VoiceLoopTestSupport
import WinstonCore

/// An `AppModel` as `Harness.withTwoBots()` builds it, Home (chat 1) and Laptop (chat 2), plus a
/// share outbox in a folder of the test's own, as the iOS app has in its App Group container.
@MainActor
private final class ShareHarness {
    let fake = FakeTDLib()
    let bed = VoiceTestBed()
    let folder: URL
    let outbox: ShareOutbox
    let model: AppModel
    private let testDefaults = TestDefaults()

    init() throws {
        folder = try makeTemporaryFolder()
        outbox = ShareOutbox(folder: folder.appending(path: "Share", directoryHint: .isDirectory))
        fake.addBotChat(id: 2, title: "Laptop", username: "laptop_bot")
        fake.addBotChat(id: 1, title: "Home", username: "home_bot")
        model = AppModel(
            link: fake.makeLink(),
            voiceLoop: bed.makeLoop(),
            defaults: testDefaults.defaults,
            pronunciationSuggester: FakePronunciationSuggester(),
            shareOutbox: outbox
        )
    }

    isolated deinit {
        model.voiceLoop.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    func startAndLoadChats() async -> Bool {
        model.start()
        return await eventually { [self] in model.authState == .ready && model.chatsLoaded }
    }

    /// Shares a file named `name` holding `data` to the agent with `agentID`, as the share
    /// extension does.
    @discardableResult
    func share(_ name: String, _ data: Data, type: String, to agentID: Int64) throws -> OutboxItem {
        let source = folder.appending(path: "Source-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try data.write(to: source.appending(path: name))
        return try outbox.add(fileAt: source.appending(path: name), named: name, typeIdentifier: type, for: agentID)
    }

    var sentDocuments: [(chatID: Int64?, path: String, caption: String?)] {
        fake.requests.compactMap { request in
            guard case .sendDocument(let chatID, let path, let caption, _) = request else { return nil }
            return (chatID, path, caption)
        }
    }

    var sentPhotos: [(chatID: Int64?, path: String, caption: String?)] {
        fake.requests.compactMap { request in
            guard case .sendPhoto(let chatID, let path, let caption, _, _) = request else { return nil }
            return (chatID, path, caption)
        }
    }
}

/// Removes the temporary copies TDLib was handed, each in a folder of its own or alone.
private func removeCopies(_ paths: [String]) {
    for path in paths {
        try? FileManager.default.removeItem(at: URL(filePath: path))
    }
}

/// The share extension's side of things in the app: the agent list it shows, and sending what
/// was shared to an agent.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppModelShareTests {
    @Test func loadingTheChatsSavesThemAsTheAgentsInTheirOrder() async throws {
        let harness = try ShareHarness()

        #expect(await harness.startAndLoadChats())

        #expect(try harness.outbox.agents() == [ShareAgent(id: 1, name: "Home"), ShareAgent(id: 2, name: "Laptop")])
    }

    @Test func loggingOutLeavesNoAgents() async throws {
        let harness = try ShareHarness()
        #expect(await harness.startAndLoadChats())

        await harness.model.logOut()

        #expect(try harness.outbox.agents().isEmpty)
    }

    @Test func aFileSharedBeforeLaunchGoesToItsAgentAsADocumentThenLeavesTheOutbox() async throws {
        let harness = try ShareHarness()
        // Laptop, while Home is the chat shown.
        try harness.share("logs.zip", Data("zip bytes".utf8), type: "public.zip-archive", to: 2)

        #expect(await harness.startAndLoadChats())

        #expect(await eventually { harness.outbox.items().isEmpty && !harness.sentDocuments.isEmpty })
        let sent = harness.sentDocuments
        defer { removeCopies(sent.map { URL(filePath: $0.path).deletingLastPathComponent().path(percentEncoded: false) }) }
        #expect(sent.count == 1)
        #expect(sent.first?.chatID == 2)
        #expect(sent.first?.caption == nil)
        // TDLib reads a copy of its own, made before the outbox's file was removed.
        let copy = URL(filePath: try #require(sent.first).path)
        #expect(copy.lastPathComponent == "logs.zip")
        #expect(try Data(contentsOf: copy) == Data("zip bytes".utf8))
        #expect(harness.model.currentChat?.id == ChatID(1))
        #expect(harness.model.errorMessage == nil)
    }

    @Test func aSharedImageGoesAsAPhoto() async throws {
        let harness = try ShareHarness()
        try harness.share("Screenshot.png", try imageData(width: 40, height: 20), type: "public.png", to: 1)

        #expect(await harness.startAndLoadChats())

        #expect(await eventually { harness.outbox.items().isEmpty && !harness.sentPhotos.isEmpty })
        let sent = harness.sentPhotos
        defer { removeCopies(sent.map(\.path)) }
        #expect(sent.count == 1)
        #expect(sent.first?.chatID == 1)
        #expect(sent.first?.caption == nil)
        #expect(try imageFileInfo(at: URL(filePath: try #require(sent.first).path)).type == "public.jpeg")
        #expect(harness.sentDocuments.isEmpty)
        #expect(harness.model.errorMessage == nil)
    }

    @Test func comingBackSendsWhatWasSharedWhileAway() async throws {
        let harness = try ShareHarness()
        #expect(await harness.startAndLoadChats())
        try harness.share("notes.txt", Data("hello".utf8), type: "public.plain-text", to: 1)

        harness.model.appDidBecomeActive()

        #expect(await eventually { harness.outbox.items().isEmpty && !harness.sentDocuments.isEmpty })
        let sent = harness.sentDocuments
        defer { removeCopies(sent.map { URL(filePath: $0.path).deletingLastPathComponent().path(percentEncoded: false) }) }
        #expect(sent.map(\.chatID) == [1])
        #expect(sent.map { URL(filePath: $0.path).lastPathComponent } == ["notes.txt"])
    }

    @Test func severalSharedFilesGoOutOldestFirst() async throws {
        let harness = try ShareHarness()
        let now = Date()
        let source = harness.folder.appending(path: "source.txt")
        try Data("a".utf8).write(to: source)
        try harness.outbox.add(fileAt: source, named: "second.txt", typeIdentifier: "public.plain-text", for: 1, now: now)
        try harness.outbox.add(fileAt: source, named: "first.txt", typeIdentifier: "public.plain-text", for: 2, now: now.addingTimeInterval(-1))

        #expect(await harness.startAndLoadChats())

        #expect(await eventually { harness.outbox.items().isEmpty && harness.sentDocuments.count == 2 })
        let sent = harness.sentDocuments
        defer { removeCopies(sent.map { URL(filePath: $0.path).deletingLastPathComponent().path(percentEncoded: false) }) }
        #expect(sent.map { URL(filePath: $0.path).lastPathComponent } == ["first.txt", "second.txt"])
        #expect(sent.map(\.chatID) == [2, 1])
    }

    @Test func aFileForAnAgentThatIsNoLongerABotChatIsDroppedAndSaysWhy() async throws {
        let harness = try ShareHarness()
        try harness.share("logs.zip", Data("zip bytes".utf8), type: "public.zip-archive", to: 99)

        #expect(await harness.startAndLoadChats())

        #expect(await eventually { harness.outbox.items().isEmpty })
        #expect(harness.model.errorMessage == "Couldn't send a shared file: its agent isn't in Winston anymore.")
        #expect(harness.sentDocuments.isEmpty)
        #expect(harness.sentPhotos.isEmpty)
    }

    @Test func aFileTDLibTurnsDownShowsTheErrorAndLeavesTheOutbox() async throws {
        let harness = try ShareHarness()
        harness.fake.fail(.sendMessage, code: 400, message: "FILE_PARTS_INVALID")
        try harness.share("logs.zip", Data("zip bytes".utf8), type: "public.zip-archive", to: 2)

        #expect(await harness.startAndLoadChats())

        #expect(await eventually { harness.outbox.items().isEmpty && harness.model.errorMessage != nil })
        #expect(harness.model.errorMessage == "FILE_PARTS_INVALID")
    }

    @Test func untilTheChatsLoadSharedFilesWait() async throws {
        let harness = try ShareHarness()
        let item = try harness.share("logs.zip", Data("zip bytes".utf8), type: "public.zip-archive", to: 2)

        // Not started, so not logged in.
        harness.model.appDidBecomeActive()
        try await settle()

        #expect(harness.outbox.items() == [item])
        #expect(harness.sentDocuments.isEmpty)
    }
}
