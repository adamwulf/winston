import Foundation
import ShareOutbox
import Testing
import TelegramLink
import TelegramLinkTestSupport
import UniformTypeIdentifiers
import VoiceLoop
import VoiceLoopTestSupport
import WinstonCore

/// Home (chat 1) and Laptop (chat 2), logged in, with a share outbox in `folder` standing in for
/// the App Group's.
@MainActor
private func twoBots(sharingIn folder: URL) -> (harness: Harness, outbox: ShareOutbox) {
    let fake = FakeTDLib()
    fake.addBotChat(id: 2, title: "Laptop", username: "laptop_bot")
    fake.addBotChat(id: 1, title: "Home", username: "home_bot")
    let outbox = ShareOutbox(folder: folder.appending(path: "Share", directoryHint: .isDirectory))
    return (Harness(fake: fake, shareOutbox: outbox), outbox)
}

/// Shares a file named `name` holding `data`, as the share extension saves one from the share
/// sheet, and returns the saved file.
private func share(_ name: String, _ data: Data, to outbox: ShareOutbox, from folder: URL) async throws -> URL {
    let source = folder.appending(path: "Source-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let file = source.appending(path: name)
    try data.write(to: file)
    let provider = try #require(NSItemProvider(contentsOf: file))
    return try #require(try await outbox.add([provider]).first)
}

/// The documents TDLib was asked to send, in order.
@MainActor
private func sentDocuments(of harness: Harness) -> [(chatID: Int64?, path: String)] {
    harness.fake.requests.compactMap { request in
        guard case .sendDocument(let chatID, let path, _, _) = request else { return nil }
        return (chatID, path)
    }
}

/// The photos TDLib was asked to send, in order.
@MainActor
private func sentPhotos(of harness: Harness) -> [(chatID: Int64?, path: String)] {
    harness.fake.requests.compactMap { request in
        guard case .sendPhoto(let chatID, let path, _, _, _) = request else { return nil }
        return (chatID, path)
    }
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
}

/// A name no other test uses, since the tests run side by side and Winston's working copies of
/// opened files share one folder.
private func uniqueName(_ name: String, _ type: String) -> String {
    "\(name)-\(UUID().uuidString).\(type)"
}

/// Waits until the opened files are copied, and whether there are `count` of them.
@MainActor
private func copied(_ count: Int, in model: AppModel) async -> Bool {
    await eventually { model.openedFilesBeingCopied == 0 && model.openedFiles.count == count }
}

/// Removes the files TDLib was handed: a document's copy and its folder, or a photo's JPEG.
private func removeUploads(_ paths: [String], documents: Bool) {
    for path in paths {
        let url = URL(filePath: path)
        try? FileManager.default.removeItem(at: documents ? url.deletingLastPathComponent() : url)
    }
}

/// What the iOS share extension saves goes the way of a file from Open in: Winston opens it into
/// the Send to Agent sheet when it's next active, and sends it to the agent picked there.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppModelShareTests {
    @Test func aSharedFileOpensInTheAgentSheetAndGoesToTheAgentPicked() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (harness, outbox) = twoBots(sharingIn: folder)
        let model = harness.model
        #expect(await harness.startAndLoadChats())
        let name = uniqueName("logs", "zip")
        let shared = try await share(name, Data("zip bytes".utf8), to: outbox, from: folder)

        // Adam comes back to Winston after sharing.
        model.appDidBecomeActive()

        #expect(await copied(1, in: model))
        let file = try #require(model.openedFiles.first)
        #expect(file.name == name)
        #expect(!file.isPhoto)
        #expect(model.isPickingAgentForOpenedFiles)
        // Winston has its own copy, so the share extension's is gone, and coming back again opens
        // nothing more.
        #expect(!exists(shared.deletingLastPathComponent()))
        #expect(outbox.files().isEmpty)
        model.appDidBecomeActive()
        #expect(model.openedFiles.count == 1)

        // Laptop, while Home is the chat shown.
        await model.sendOpenedFiles(to: ChatID(2))

        let sent = sentDocuments(of: harness)
        defer { removeUploads(sent.map(\.path), documents: true) }
        #expect(sent.map(\.chatID) == [2])
        #expect(sent.map { URL(filePath: $0.path).lastPathComponent } == [name])
        #expect(model.openedFiles.isEmpty)
        #expect(model.currentChat?.id == ChatID(1))
    }

    @Test func aSharedScreenshotGoesAsAPhotoAndAnAnimatedGIFAsADocument() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (harness, outbox) = twoBots(sharingIn: folder)
        let model = harness.model
        #expect(await harness.startAndLoadChats())
        try await share(uniqueName("Screenshot", "png"), try imageData(width: 40, height: 20), to: outbox, from: folder)
        try await share(uniqueName("dancing", "gif"), try imageData(width: 40, height: 30, type: .gif, frames: 3), to: outbox, from: folder)

        model.appDidBecomeActive()

        #expect(await copied(2, in: model))
        // In the order they were shared.
        #expect(model.openedFiles.map(\.isPhoto) == [true, false])
        await model.sendOpenedFiles(to: ChatID(1))

        let photos = sentPhotos(of: harness)
        let documents = sentDocuments(of: harness)
        defer {
            removeUploads(photos.map(\.path), documents: false)
            removeUploads(documents.map(\.path), documents: true)
        }
        #expect(photos.map(\.chatID) == [1])
        #expect(try imageFileInfo(at: URL(filePath: try #require(photos.first).path)).type == UTType.jpeg.identifier)
        #expect(documents.map(\.chatID) == [1])
        #expect(documents.map { URL(filePath: $0.path).pathExtension } == ["gif"])
    }

    @Test func filesSharedBeforeLoginWaitForTheChats() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (harness, outbox) = twoBots(sharingIn: folder)
        let model = harness.model
        try await share(uniqueName("notes", "txt"), Data("hello".utf8), to: outbox, from: folder)

        // The activation at launch, before TDLib has its session.
        model.appDidBecomeActive()

        #expect(await copied(1, in: model))
        #expect(!model.isPickingAgentForOpenedFiles)
        #expect(await harness.startAndLoadChats())
        #expect(model.isPickingAgentForOpenedFiles)
    }

    @Test func aFileStillBeingCopiedIsNotOpenedAgain() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (harness, outbox) = twoBots(sharingIn: folder)
        let model = harness.model
        #expect(await harness.startAndLoadChats())
        let shared = try await share(uniqueName("big", "zip"), Data("zip bytes".utf8), to: outbox, from: folder)
        // As while an iCloud Drive download is under way.
        let hold = try WriteHold(on: shared)

        model.appDidBecomeActive()
        model.appDidBecomeActive()

        #expect(model.openedFiles.count == 1)
        #expect(model.openedFilesBeingCopied == 1)
        hold.release()
        #expect(await copied(1, in: model))
        #expect(outbox.files().isEmpty)
        model.cancelOpenedFiles()
    }

    @Test func cancelWhileCopyingRemovesTheSharedFile() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (harness, outbox) = twoBots(sharingIn: folder)
        let model = harness.model
        #expect(await harness.startAndLoadChats())
        let shared = try await share(uniqueName("big", "zip"), Data("zip bytes".utf8), to: outbox, from: folder)
        let hold = try WriteHold(on: shared)
        model.appDidBecomeActive()

        model.cancelOpenedFiles()
        hold.release()
        await model.waitForOpenedFileCopies()

        #expect(model.openedFiles.isEmpty)
        #expect(outbox.files().isEmpty)
        model.appDidBecomeActive()
        #expect(model.openedFiles.isEmpty)
        #expect(sentDocuments(of: harness).isEmpty)
    }

    @Test func aSharedFileThatCannotBeCopiedStaysForTryAgainUntilCancel() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (harness, outbox) = twoBots(sharingIn: folder)
        let model = harness.model
        #expect(await harness.startAndLoadChats())
        // A folder in the outbox, which Winston's copy turns down.
        let item = outbox.folder.appending(path: "Outbox/\(UUID().uuidString)/reports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)

        model.appDidBecomeActive()

        #expect(await copied(1, in: model))
        #expect(model.openedFiles.first?.copyError == "Winston can send files, but not folders.")
        // Kept for Try Again, and not opened a second time meanwhile.
        #expect(outbox.files().count == 1)
        model.appDidBecomeActive()
        #expect(model.openedFiles.count == 1)

        model.cancelOpenedFiles()

        #expect(outbox.files().isEmpty)
    }

    @Test func whatAnInterruptedShareLeftAnHourAgoIsRemoved() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (harness, outbox) = twoBots(sharingIn: folder)
        let model = harness.model
        let staging = outbox.folder.appending(path: "Staging", directoryHint: .isDirectory)
        let old = staging.appending(path: "old/item", directoryHint: .isDirectory)
        let recent = staging.appending(path: "recent/item", directoryHint: .isDirectory)
        for batch in [old, recent] {
            try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
            try Data("half".utf8).write(to: batch.appending(path: "big.zip"))
        }
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSinceNow: -2 * 60 * 60)],
            ofItemAtPath: staging.appending(path: "old").path(percentEncoded: false)
        )

        model.appDidBecomeActive()

        #expect(await eventually { !exists(staging.appending(path: "old")) })
        #expect(exists(recent))
        // Nothing half copied is opened.
        #expect(model.openedFiles.isEmpty)
    }
}
