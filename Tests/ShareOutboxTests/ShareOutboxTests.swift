import Foundation
@testable import ShareOutbox
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

    /// A provider for a file named `name` holding `text`, with its content and its file URL, as
    /// Files hands one over.
    func fileProvider(_ name: String, _ text: String) throws -> NSItemProvider {
        try #require(NSItemProvider(contentsOf: try sourceFile(name, text)))
    }

    /// Stages and publishes, as the extension does when Adam taps Done.
    func share(_ providers: [NSItemProvider]) async throws -> [URL] {
        try outbox.publish(try await outbox.stage(providers))
    }

    /// What's in the share folder's `name` folder, by name. None if it doesn't exist.
    func contents(of name: String) -> [String] {
        let folder = outbox.folder.appending(path: name, directoryHint: .isDirectory)
        return (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
}

private func text(of url: URL) throws -> String {
    String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

/// A provider holding only `data` as `type`, with no file URL, as the screenshot editor and Photos
/// hand an image over.
private func contentProvider(_ data: Data, type: UTType, suggestedName: String?) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
        completion(data, nil)
        return nil
    }
    provider.suggestedName = suggestedName
    return provider
}

/// What the share extension copies, and what Winston sees of it.
@Suite struct ShareOutboxStageTests {
    @Test func aFileIsCopiedUnderItsOwnNameAndWinstonSeesItOncePublished() async throws {
        let folder = TestFolder()
        let source = try folder.sourceFile("nightly logs.zip", "zip bytes")
        // Registers the file's content as a zip archive and its file URL, with no suggested name.
        let provider = try #require(NSItemProvider(contentsOf: source))

        let staged = try await folder.outbox.stage([provider])

        #expect(staged.count == 1)
        // Not until Adam taps Done.
        #expect(await folder.outbox.files().isEmpty)
        let published = try folder.outbox.publish(staged)
        #expect(published.map(\.lastPathComponent) == ["nightly logs.zip"])
        #expect(try text(of: try #require(published.first)) == "zip bytes")
        #expect(await folder.outbox.files() == published)
        // A copy: the shared file stays where it was.
        #expect(exists(source))
        #expect(folder.contents(of: "Staging").isEmpty)
    }

    @Test func discardingRemovesWhatWasStagedAndWinstonNeverSeesIt() async throws {
        let folder = TestFolder()
        let staged = try await folder.outbox.stage([try folder.fileProvider("notes.txt", "hello")])

        folder.outbox.discard(staged)

        #expect(folder.contents(of: "Staging").isEmpty)
        #expect(await folder.outbox.files().isEmpty)
    }

    @Test func imageContentTakesTheSuggestedNameAndTheTypesExtension() async throws {
        let folder = TestFolder()
        let provider = contentProvider(Data("png bytes".utf8), type: .png, suggestedName: "Screenshot 2026-11-20 at 2.35.00 PM")

        let saved = try await folder.share([provider])

        #expect(saved.map(\.lastPathComponent) == ["Screenshot 2026-11-20 at 2.35.00 PM.png"])
        #expect(try text(of: try #require(saved.first)) == "png bytes")
    }

    @Test func aFileURLAloneIsCopiedUnderItsName() async throws {
        let folder = TestFolder()
        let source = try folder.sourceFile("report.txt", "All 214 tests passed.")
        let provider = NSItemProvider(object: source as NSURL)

        let saved = try await folder.share([provider])

        #expect(saved.map(\.lastPathComponent) == ["report.txt"])
        #expect(try text(of: try #require(saved.first)) == "All 214 tests passed.")
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

        let saved = try await folder.share([provider])

        #expect(saved.map(\.lastPathComponent) == ["logs.zip"])
        #expect(try text(of: try #require(saved.first)) == "zip bytes")
    }

    @Test func aSlashInTheSuggestedNameCannotLeaveTheFilesFolder() async throws {
        let folder = TestFolder()
        let provider = contentProvider(Data("a".utf8), type: .plainText, suggestedName: "../a/b.txt")

        let saved = try await folder.share([provider])

        let file = try #require(saved.first)
        #expect(file.lastPathComponent == "..-a-b.txt")
        #expect(await folder.outbox.files() == [file])
    }

    @Test func severalAreListedInTheOrderGivenAcrossShares() async throws {
        let folder = TestFolder()
        let first = try await folder.share(try ["one.txt", "two.zip", "three.pdf"].map { try folder.fileProvider($0, $0) })
        let second = try await folder.share([try folder.fileProvider("four.txt", "four")])

        #expect(await folder.outbox.files() == first + second)
        #expect(first.map(\.lastPathComponent) == ["one.txt", "two.zip", "three.pdf"])
    }

    @Test func twoFilesWithTheSameNameAreBothKept() async throws {
        let folder = TestFolder()

        let saved = try await folder.share([
            try folder.fileProvider("image.png", "first"),
            try folder.fileProvider("image.png", "second"),
        ])

        #expect(saved.map(\.lastPathComponent) == ["image.png", "image.png"])
        #expect(try saved.map(text) == ["first", "second"])
    }

    @Test func aBatchWhoseFilesWinstonTookIsRemoved() async throws {
        let folder = TestFolder()
        let saved = try await folder.share([try folder.fileProvider("one.txt", "1"), try folder.fileProvider("two.txt", "2")])

        // As Winston removes each file's folder once it has its own copy.
        for file in saved {
            try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }

        #expect(await folder.outbox.files().isEmpty)
        #expect(folder.contents(of: "Outbox").isEmpty)
    }

    @Test func aBatchThatCannotBeReadNowIsKeptForTheNextLook() async throws {
        let folder = TestFolder()
        let saved = try await folder.share([try folder.fileProvider("notes.txt", "hello")])
        let batch = try #require(saved.first).deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: batch.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: batch.path(percentEncoded: false)) }

        #expect(await folder.outbox.files().isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: batch.path(percentEncoded: false))
        #expect(await folder.outbox.files() == saved)
    }

    @Test func aWebLinkIsNotAFileAndNothingIsStaged() async throws {
        let folder = TestFolder()
        let link = try #require(URL(string: "https://example.com/report.txt"))
        let provider = NSItemProvider(object: link as NSURL)

        #expect(!ShareOutbox.canAdd(provider))
        await #expect(throws: ShareOutbox.AddFailure.noFile) {
            try await folder.outbox.stage([provider])
        }

        #expect(folder.contents(of: "Staging").isEmpty)
    }

    @Test func aFolderIsTurnedDownAndNothingIsStaged() async throws {
        let folder = TestFolder()
        let shared = folder.url.appending(path: "reports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let provider = NSItemProvider(object: shared as NSURL)

        await #expect(throws: ShareOutbox.AddFailure.folder) {
            try await folder.outbox.stage([provider])
        }

        #expect(folder.contents(of: "Staging").isEmpty)
    }

    @Test func aFolderHandedOverAsContentIsTurnedDownToo() async throws {
        let folder = TestFolder()
        let shared = folder.url.appending(path: "Report.rtfd", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data("text".utf8).write(to: shared.appending(path: "TXT.rtf"))
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.data.identifier, visibility: .all) { completion in
            completion(shared, false, nil)
            return nil
        }

        await #expect(throws: ShareOutbox.AddFailure.folder) {
            try await folder.outbox.stage([provider])
        }

        #expect(folder.contents(of: "Staging").isEmpty)
    }

    @Test func whenOneCannotBeCopiedNoneIs() async throws {
        let folder = TestFolder()
        let shared = folder.url.appending(path: "reports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)

        await #expect(throws: ShareOutbox.AddFailure.folder) {
            try await folder.outbox.stage([try folder.fileProvider("notes.txt", "hello"), NSItemProvider(object: shared as NSURL)])
        }

        #expect(folder.contents(of: "Staging").isEmpty)
        #expect(await folder.outbox.files().isEmpty)
    }

    @Test func filesAndContentCanBeAddedButNotALinkAlone() throws {
        let folder = TestFolder()

        #expect(ShareOutbox.canAdd(try folder.fileProvider("notes.txt", "hello")))
        #expect(ShareOutbox.canAdd(contentProvider(Data(), type: .heic, suggestedName: nil)))
        #expect(ShareOutbox.canAdd(NSItemProvider(object: try folder.sourceFile("a.zip", "a") as NSURL)))
    }
}

/// The name a shared file goes under, from what the sharing app suggests and the file it loads.
@Suite struct ShareFileNameTests {
    private let temporary = URL(filePath: "/tmp/download.tmp")

    @Test func aSuggestedNameWithTheTypesExtensionIsKept() {
        #expect(ShareOutbox.fileName(suggested: "IMG_0042.JPG", loaded: temporary, type: .jpeg) == "IMG_0042.JPG")
    }

    @Test func aSuggestedNameWithoutOneTakesTheTypesNotATemporaryFilesSuffix() {
        #expect(ShareOutbox.fileName(suggested: "Report", loaded: temporary, type: .pdf) == "Report.pdf")
    }

    @Test func aSuggestedNameTakesTheLoadedFilesExtensionWhenItIsTheTypes() {
        let loaded = URL(filePath: "/tmp/IMG_0042.heic")
        #expect(ShareOutbox.fileName(suggested: "Photo", loaded: loaded, type: .heic) == "Photo.heic")
    }

    @Test func withNoSuggestedNameTheLoadedFilesNameIsUsedWithTheTypesExtension() {
        #expect(ShareOutbox.fileName(suggested: nil, loaded: URL(filePath: "/tmp/scan.pdf"), type: .pdf) == "scan.pdf")
        #expect(ShareOutbox.fileName(suggested: "", loaded: temporary, type: .pdf) == "download.pdf")
    }
}

/// What an interrupted or cancelled share leaves behind.
@Suite struct ShareOutboxLeftoverTests {
    @Test func leftoversInStagingFromBeforeTheCutoffGoAndLaterOnesStay() async throws {
        let folder = TestFolder()
        let staging = folder.outbox.folder.appending(path: "Staging", directoryHint: .isDirectory)
        // As an interrupted copy leaves it: a batch folder with a half-copied file.
        let old = staging.appending(path: "old/000", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: old.appending(path: "big.zip"))
        let cutoff = Date()
        let new = staging.appending(path: "new/000", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.creationDate: cutoff.addingTimeInterval(-60)],
            ofItemAtPath: staging.appending(path: "old").path(percentEncoded: false)
        )
        try FileManager.default.setAttributes(
            [.creationDate: cutoff.addingTimeInterval(60)],
            ofItemAtPath: staging.appending(path: "new").path(percentEncoded: false)
        )
        let saved = try await folder.share([try folder.fileProvider("a.txt", "a")])

        let removed = await folder.outbox.removeLeftovers(before: cutoff)

        #expect(removed == 1)
        #expect(folder.contents(of: "Staging") == ["new"])
        // A published file isn't a leftover.
        #expect(await folder.outbox.files() == saved)
    }

    @Test func withNoStagingThereAreNoLeftovers() async {
        #expect(await TestFolder().outbox.removeLeftovers(before: Date()) == 0)
    }

    @Test func beforeAnythingIsSharedThereIsNothing() async {
        #expect(await TestFolder().outbox.files().isEmpty)
    }
}
