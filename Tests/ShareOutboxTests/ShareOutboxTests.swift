import Foundation
import ShareOutbox
import Testing
import UniformTypeIdentifiers

/// A share folder of a test's own, removed at the end of the test.
private final class TestFolder {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "ShareOutboxTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    var outbox: ShareOutbox {
        ShareOutbox(folder: url.appending(path: "Share", directoryHint: .isDirectory))
    }

    /// Writes `text` to a file named `name` outside the share folder, as a file the share sheet
    /// hands over, and returns it.
    func sourceFile(_ name: String, _ text: String) throws -> URL {
        let folder = url.appending(path: "Source-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name)
        try Data(text.utf8).write(to: file)
        return file
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
}

@Suite struct ShareAgentListTests {
    @Test func savedAgentsReadBackInTheSameOrder() throws {
        let folder = TestFolder()
        let agents = [ShareAgent(id: 1, name: "Home"), ShareAgent(id: -1002, name: "Laptop")]

        try folder.outbox.saveAgents(agents)

        #expect(try folder.outbox.agents() == agents)
    }

    @Test func savingAgainReplacesTheList() throws {
        let folder = TestFolder()
        try folder.outbox.saveAgents([ShareAgent(id: 1, name: "Home"), ShareAgent(id: 2, name: "Laptop")])

        try folder.outbox.saveAgents([])

        #expect(try folder.outbox.agents().isEmpty)
    }

    @Test func beforeWinstonSavesAnyThereAreNone() throws {
        #expect(try TestFolder().outbox.agents().isEmpty)
    }
}

@Suite struct OutboxManifestTests {
    @Test func anAddedFileReadsBackWithItsAgentNameAndType() throws {
        let folder = TestFolder()
        let source = try folder.sourceFile("source.zip", "zip bytes")
        let sharedAt = Date(timeIntervalSinceReferenceDate: 815_000_000.25)

        let added = try folder.outbox.add(fileAt: source, named: "logs.zip", typeIdentifier: "public.zip-archive", for: 2, now: sharedAt)

        let items = folder.outbox.items()
        #expect(items == [added])
        let item = try #require(items.first)
        #expect(item.agentID == 2)
        #expect(item.fileName == "logs.zip")
        #expect(item.typeIdentifier == "public.zip-archive")
        #expect(item.createdAt == sharedAt)
        #expect(item.fileURL.lastPathComponent == "logs.zip")
        #expect(try Data(contentsOf: item.fileURL) == Data("zip bytes".utf8))
        // A copy: the shared file stays where it was.
        #expect(exists(source))
    }

    @Test func itemsAreListedOldestFirst() throws {
        let folder = TestFolder()
        let source = try folder.sourceFile("note.txt", "hello")
        let now = Date()
        try folder.outbox.add(fileAt: source, named: "second.txt", typeIdentifier: "public.plain-text", for: 1, now: now)
        try folder.outbox.add(fileAt: source, named: "first.txt", typeIdentifier: "public.plain-text", for: 1, now: now.addingTimeInterval(-0.5))
        try folder.outbox.add(fileAt: source, named: "third.txt", typeIdentifier: "public.plain-text", for: 1, now: now.addingTimeInterval(0.5))

        #expect(folder.outbox.items().map(\.fileName) == ["first.txt", "second.txt", "third.txt"])
    }

    @Test func aFileNamedLikeAManifestKeepsItsName() throws {
        let folder = TestFolder()
        let source = try folder.sourceFile("manifest.json", "{}")

        try folder.outbox.add(fileAt: source, named: "manifest.json", typeIdentifier: "public.json", for: 1)

        let item = try #require(folder.outbox.items().first)
        #expect(item.fileName == "manifest.json")
        #expect(try Data(contentsOf: item.fileURL) == Data("{}".utf8))
    }

    @Test func aSlashInTheNameCannotLeaveTheItemsFolder() throws {
        let folder = TestFolder()
        let source = try folder.sourceFile("a.txt", "a")

        let item = try folder.outbox.add(fileAt: source, named: "../a/b.txt", typeIdentifier: "public.plain-text", for: 1)

        #expect(item.fileName == "..-a-b.txt")
        #expect(item.fileURL.deletingLastPathComponent() == item.folder)
    }

    @Test func aFileThatCannotBeCopiedLeavesNothingBehind() throws {
        let folder = TestFolder()
        let missing = folder.url.appending(path: "gone.txt")

        #expect(throws: (any Error).self) {
            try folder.outbox.add(fileAt: missing, named: "gone.txt", typeIdentifier: "public.plain-text", for: 1)
        }

        #expect(folder.outbox.items().isEmpty)
        let outboxFolder = folder.outbox.folder.appending(path: "Outbox")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outboxFolder.path(percentEncoded: false)).isEmpty)
    }

    @Test func aFolderWithoutItsManifestIsNotListed() throws {
        let folder = TestFolder()
        // As the share extension leaves an item while it's still copying the file.
        let unfinished = folder.outbox.folder.appending(path: "Outbox/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unfinished, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: unfinished.appending(path: "big.zip"))

        #expect(folder.outbox.items().isEmpty)
    }

    @Test func removingAnItemRemovesItsFileAndManifest() throws {
        let folder = TestFolder()
        let source = try folder.sourceFile("a.txt", "a")
        let item = try folder.outbox.add(fileAt: source, named: "a.txt", typeIdentifier: "public.plain-text", for: 1)

        try folder.outbox.remove(item)

        #expect(folder.outbox.items().isEmpty)
        #expect(!exists(item.folder))
        let outboxFolder = folder.outbox.folder.appending(path: "Outbox")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outboxFolder.path(percentEncoded: false)).isEmpty)
    }
}

/// What a fake sender was handed, in order, and whether each file was still there when it was.
private actor SentLog {
    private(set) var sent: [(fileName: String, agentID: Int64, fileExisted: Bool)] = []

    func record(_ item: OutboxItem) {
        sent.append((item.fileName, item.agentID, exists(item.fileURL)))
    }
}

@Suite struct OutboxSendTests {
    @Test func eachItemIsSentOldestFirstThenRemoved() async throws {
        let folder = TestFolder()
        let source = try folder.sourceFile("a.png", "png")
        let now = Date()
        try folder.outbox.add(fileAt: source, named: "screenshot.png", typeIdentifier: "public.png", for: 2, now: now)
        try folder.outbox.add(fileAt: source, named: "logs.zip", typeIdentifier: "public.zip-archive", for: 1, now: now.addingTimeInterval(-1))
        let log = SentLog()

        let count = await folder.outbox.sendAll { item in await log.record(item) }

        #expect(count == 2)
        let sent = await log.sent
        #expect(sent.map(\.fileName) == ["logs.zip", "screenshot.png"])
        #expect(sent.map(\.agentID) == [1, 2])
        #expect(sent.map(\.fileExisted) == [true, true])
        #expect(folder.outbox.items().isEmpty)
        let outboxFolder = folder.outbox.folder.appending(path: "Outbox")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outboxFolder.path(percentEncoded: false)).isEmpty)
    }

    @Test func anEmptyOutboxSendsNothing() async {
        let log = SentLog()

        let count = await TestFolder().outbox.sendAll { item in await log.record(item) }

        #expect(count == 0)
        #expect(await log.sent.isEmpty)
    }

    @Test func theAgentListIsLeftAlone() async throws {
        let folder = TestFolder()
        let agents = [ShareAgent(id: 1, name: "Home")]
        try folder.outbox.saveAgents(agents)
        try folder.outbox.add(fileAt: try folder.sourceFile("a.txt", "a"), named: "a.txt", typeIdentifier: "public.plain-text", for: 1)

        await folder.outbox.sendAll { _ in }

        #expect(try folder.outbox.agents() == agents)
    }
}

/// What the share extension does with what the share sheet hands it.
@Suite struct OutboxItemProviderTests {
    @Test func aFileIsCopiedUnderItsNameWithItsType() async throws {
        let folder = TestFolder()
        let source = try folder.sourceFile("nightly logs.zip", "zip bytes")
        // Registers the file's content as a zip archive and its file URL, with no suggested name.
        let provider = try #require(NSItemProvider(contentsOf: source))

        let item = try await folder.outbox.add(provider, for: 7)

        #expect(item.agentID == 7)
        #expect(item.fileName == "nightly logs.zip")
        #expect(item.typeIdentifier == UTType.zip.identifier)
        #expect(try Data(contentsOf: item.fileURL) == Data("zip bytes".utf8))
        #expect(folder.outbox.items() == [item])
    }

    @Test func imageDataTakesTheSuggestedNameAndTheTypesExtension() async throws {
        let folder = TestFolder()
        let provider = NSItemProvider(item: Data("png bytes".utf8) as NSData, typeIdentifier: UTType.png.identifier)
        provider.suggestedName = "Screenshot 2026-11-20 at 2.35.00 PM"

        let item = try await folder.outbox.add(provider, for: 1)

        #expect(item.fileName == "Screenshot 2026-11-20 at 2.35.00 PM.png")
        #expect(item.typeIdentifier == UTType.png.identifier)
        #expect(try Data(contentsOf: item.fileURL) == Data("png bytes".utf8))
    }

    @Test func aFileURLIsCopiedUnderItsName() async throws {
        let folder = TestFolder()
        let source = try folder.sourceFile("report.txt", "All 214 tests passed.")
        let provider = NSItemProvider(object: source as NSURL)

        let item = try await folder.outbox.add(provider, for: 1)

        #expect(item.fileName == "report.txt")
        #expect(item.typeIdentifier == UTType.plainText.identifier)
        #expect(try Data(contentsOf: item.fileURL) == Data("All 214 tests passed.".utf8))
    }

    @Test func whenTheFileURLCannotBeReadItsContentIsCopiedUnderTheSuggestedName() async throws {
        let folder = TestFolder()
        let provider = NSItemProvider()
        provider.registerObject(folder.url.appending(path: "gone.zip") as NSURL, visibility: .all)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.zip.identifier, visibility: .all) { completion in
            completion(Data("zip bytes".utf8), nil)
            return nil
        }
        provider.suggestedName = "logs.zip"

        let item = try await folder.outbox.add(provider, for: 1)

        #expect(item.fileName == "logs.zip")
        #expect(item.typeIdentifier == UTType.zip.identifier)
        #expect(try Data(contentsOf: item.fileURL) == Data("zip bytes".utf8))
        #expect(folder.outbox.items() == [item])
    }

    @Test func aWebLinkIsNotAFile() async throws {
        let folder = TestFolder()
        let link = try #require(URL(string: "https://example.com/report.txt"))
        let provider = NSItemProvider(object: link as NSURL)

        await #expect(throws: ShareOutbox.AddFailure.self) {
            try await folder.outbox.add(provider, for: 1)
        }

        #expect(folder.outbox.items().isEmpty)
    }
}
