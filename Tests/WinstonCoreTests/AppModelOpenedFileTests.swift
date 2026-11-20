import Foundation
import Testing
import TelegramLink
import TelegramLinkTestSupport
import UniformTypeIdentifiers
import VoiceLoop
import VoiceLoopTestSupport
import WinstonCore

/// Home (chat 1) and Laptop (chat 2), as `Harness.withTwoBots()` has them, on an account that may
/// not be logged in yet, with `inbox` standing in for iOS's Documents/Inbox.
@MainActor
private func twoBots(isLoggedIn: Bool = true, inbox: URL? = nil) -> Harness {
    let fake = FakeTDLib(isLoggedIn: isLoggedIn)
    fake.addBotChat(id: 2, title: "Laptop", username: "laptop_bot")
    fake.addBotChat(id: 1, title: "Home", username: "home_bot")
    return Harness(fake: fake, openedFileInbox: inbox)
}

/// The documents TDLib was asked to send, in order.
@MainActor
private func sentDocuments(of harness: Harness) -> [(chatID: Int64?, path: String, caption: String?)] {
    harness.fake.requests.compactMap { request in
        guard case .sendDocument(let chatID, let path, let caption, _) = request else { return nil }
        return (chatID, path, caption)
    }
}

/// The photos TDLib was asked to send, in order.
@MainActor
private func sentPhotos(of harness: Harness) -> [(chatID: Int64?, path: String, caption: String?)] {
    harness.fake.requests.compactMap { request in
        guard case .sendPhoto(let chatID, let path, let caption, _, _) = request else { return nil }
        return (chatID, path, caption)
    }
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
}

/// Writes `data` to a file named `name` in `folder`, and returns the file.
private func writeFile(_ name: String, _ data: Data, in folder: URL) throws -> URL {
    let file = folder.appending(path: name)
    try data.write(to: file)
    return file
}

/// Waits until the opened files are copied, and whether there are `count` of them.
@MainActor
private func copied(_ count: Int, in model: AppModel) async -> Bool {
    await eventually { model.openedFilesBeingCopied == 0 && model.openedFiles.count == count }
}

/// Removes TDLib's copies of sent documents, each in a folder of its own.
private func removeDocumentCopies(_ paths: [String]) {
    for path in paths {
        try? FileManager.default.removeItem(at: URL(filePath: path).deletingLastPathComponent())
    }
}

/// A file opened in Winston from another app: copied, offered in the agent sheet once Winston is
/// logged in with its bot chats, and sent to the agent picked, or cancelled.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct OpenedFileTests {
    @Test func aZipOpenedBeforeLoginWaitsForTheChatsThenGoesAsADocumentToTheAgentPicked() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = try writeFile("logs.zip", Data("zip bytes".utf8), in: folder)
        let harness = twoBots(isLoggedIn: false)
        let model = harness.model

        model.openFile(at: zip)
        #expect(await copied(1, in: model))
        let file = try #require(model.openedFiles.first)
        #expect(file.name == "logs.zip")
        #expect(!file.isPhoto)
        #expect(model.openedFileCount == 1)

        // Not logged in: the sheet waits, and so does the file.
        model.start()
        #expect(await eventually { model.authState == .needsPhoneNumber })
        #expect(!model.isPickingAgentForOpenedFiles)
        try await model.submitPhoneNumber("+15551234567")
        #expect(await eventually { model.authState == .needsCode })
        try await model.submitCode("12345")
        #expect(await eventually { model.authState == .ready && model.chatsLoaded })
        #expect(model.isPickingAgentForOpenedFiles)
        #expect(model.openedFiles == [file])

        // Laptop, while Home is the chat shown.
        #expect(model.currentChat?.id == ChatID(1))
        await model.sendOpenedFiles(to: ChatID(2))

        let sent = sentDocuments(of: harness)
        defer { removeDocumentCopies(sent.map(\.path)) }
        #expect(sent.count == 1)
        #expect(sent.first?.chatID == 2)
        #expect(sent.first?.caption == nil)
        // TDLib reads Winston's copy, which stays for its upload.
        let copy = URL(filePath: try #require(sent.first).path)
        #expect(copy.lastPathComponent == "logs.zip")
        #expect(try Data(contentsOf: copy) == Data("zip bytes".utf8))
        #expect(sentPhotos(of: harness).isEmpty)
        #expect(model.openedFiles.isEmpty)
        #expect(!model.isPickingAgentForOpenedFiles)
        #expect(model.openedFilesSendingTo == nil)
        #expect(model.openedFileError == nil)
        #expect(model.currentChat?.id == ChatID(1))
        // Adam's own file, outside the inbox, stays.
        #expect(exists(zip))
        #expect(model.errorMessage == nil)
        #expect(!model.isSendingAttachment)
    }

    @Test func whileItIsSentTheAgentIsMarkedAndAnotherPickDoesNothing() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = try writeFile("manual.pdf", try pdfData(), in: folder)
        let harness = twoBots()
        let model = harness.model
        #expect(await harness.startAndLoadChats())
        model.openFile(at: pdf)
        #expect(await copied(1, in: model))
        harness.fake.hold(.sendMessage)

        let send = Task { await model.sendOpenedFiles(to: ChatID(1)) }

        #expect(await eventually { harness.fake.isWaiting(on: .sendMessage) })
        #expect(model.openedFilesSendingTo == ChatID(1))
        // Neither another agent nor Cancel does anything meanwhile.
        await model.sendOpenedFiles(to: ChatID(2))
        model.cancelOpenedFiles()
        #expect(model.openedFiles.count == 1)
        harness.fake.release(.sendMessage)
        await send.value

        let sent = sentDocuments(of: harness)
        defer { removeDocumentCopies(sent.map(\.path)) }
        #expect(sent.map(\.chatID) == [1])
        #expect(sent.map { URL(filePath: $0.path).lastPathComponent } == ["manual.pdf"])
        #expect(model.openedFilesSendingTo == nil)
        #expect(model.openedFiles.isEmpty)
    }

    @Test func aStillImageGoesAsAPhotoAndWinstonsCopyOfItIsRemoved() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = "Screenshot-\(UUID().uuidString).png"
        let png = try writeFile(name, try imageData(width: 40, height: 20), in: folder)
        let harness = twoBots()
        let model = harness.model
        #expect(await harness.startAndLoadChats())

        model.openFile(at: png)
        #expect(await copied(1, in: model))
        #expect(model.openedFiles.first?.isPhoto == true)
        let copyFolders = try copyFolders(named: name, besides: folder)
        #expect(copyFolders.count == 1)
        await model.sendOpenedFiles(to: ChatID(1))

        let sent = sentPhotos(of: harness)
        defer { sent.forEach { try? FileManager.default.removeItem(at: URL(filePath: $0.path)) } }
        #expect(sent.count == 1)
        #expect(sent.first?.chatID == 1)
        #expect(sent.first?.caption == nil)
        #expect(try imageFileInfo(at: URL(filePath: try #require(sent.first).path))
            == ImageFileInfo(type: UTType.jpeg.identifier, width: 40, height: 20))
        #expect(sentDocuments(of: harness).isEmpty)
        // TDLib uploads the JPEG, so Winston's copy of the PNG is gone.
        #expect(copyFolders.allSatisfy { !exists($0) })
        #expect(exists(png))
        #expect(model.openedFiles.isEmpty)
        #expect(model.openedFileError == nil)
    }

    @Test func anAnimatedGIFGoesAsADocumentSoItKeepsItsFrames() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gifData = try imageData(width: 40, height: 30, type: .gif, frames: 3)
        let gif = try writeFile("dancing.gif", gifData, in: folder)
        let harness = twoBots()
        let model = harness.model
        #expect(await harness.startAndLoadChats())

        model.openFile(at: gif)
        #expect(await copied(1, in: model))
        #expect(model.openedFiles.first?.isPhoto == false)
        await model.sendOpenedFiles(to: ChatID(2))

        let sent = sentDocuments(of: harness)
        defer { removeDocumentCopies(sent.map(\.path)) }
        #expect(sent.map(\.chatID) == [2])
        #expect(try Data(contentsOf: URL(filePath: try #require(sent.first).path)) == gifData)
        #expect(sentPhotos(of: harness).isEmpty)
    }

    @Test func filesOpenedTogetherGoToTheAgentInTheOrderTheyCame() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let notes = try writeFile("notes.txt", Data("hello".utf8), in: folder)
        let photo = try writeFile("photo.jpg", try imageData(width: 40, height: 30, type: .jpeg), in: folder)
        let harness = twoBots()
        let model = harness.model
        #expect(await harness.startAndLoadChats())

        model.openFile(at: notes)
        #expect(await copied(1, in: model))
        model.openFile(at: photo)
        #expect(await copied(2, in: model))
        #expect(model.openedFiles.map(\.name) == ["notes.txt", "photo.jpg"])
        #expect(model.openedFileCount == 2)
        await model.sendOpenedFiles(to: ChatID(2))

        let documents = sentDocuments(of: harness)
        let photos = sentPhotos(of: harness)
        defer {
            removeDocumentCopies(documents.map(\.path))
            photos.forEach { try? FileManager.default.removeItem(at: URL(filePath: $0.path)) }
        }
        #expect(documents.map(\.chatID) == [2])
        #expect(photos.map(\.chatID) == [2])
        // The document first.
        let sendRequests = harness.fake.requests.filter {
            switch $0 {
            case .sendDocument, .sendPhoto: true
            default: false
            }
        }
        guard case .sendDocument = sendRequests.first else {
            Issue.record("the document wasn't sent first: \(sendRequests)")
            return
        }
        #expect(model.openedFiles.isEmpty)
    }

    @Test func aSendTDLibTurnsDownKeepsTheFileWithTheErrorForAnotherPick() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = try writeFile("logs.zip", Data("zip bytes".utf8), in: folder)
        let harness = twoBots()
        let model = harness.model
        #expect(await harness.startAndLoadChats())
        model.openFile(at: zip)
        #expect(await copied(1, in: model))
        let file = try #require(model.openedFiles.first)
        harness.fake.fail(.sendMessage, code: 400, message: "FILE_PARTS_INVALID")

        await model.sendOpenedFiles(to: ChatID(1))

        let refused = sentDocuments(of: harness)
        #expect(refused.map(\.chatID) == [1])
        #expect(model.openedFileError == "FILE_PARTS_INVALID")
        #expect(model.openedFiles == [file])
        #expect(model.isPickingAgentForOpenedFiles)
        // In the sheet, not the chat screen's alert, which can't show over it.
        #expect(model.errorMessage == nil)
        let copy = URL(filePath: try #require(refused.first).path)
        #expect(exists(copy))

        harness.fake.succeed(.sendMessage)
        await model.sendOpenedFiles(to: ChatID(2))

        let sent = sentDocuments(of: harness)
        defer { removeDocumentCopies(sent.map(\.path)) }
        #expect(sent.map(\.chatID) == [1, 2])
        #expect(sent.last?.path == copy.path(percentEncoded: false))
        #expect(model.openedFiles.isEmpty)
        #expect(model.openedFileError == nil)
        #expect(!model.isPickingAgentForOpenedFiles)
    }

    @Test func cancelRemovesWinstonsCopyAndSendsNothing() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = "cancelled-\(UUID().uuidString).zip"
        let zip = try writeFile(name, Data("zip bytes".utf8), in: folder)
        let harness = twoBots()
        let model = harness.model
        #expect(await harness.startAndLoadChats())
        model.openFile(at: zip)
        #expect(await copied(1, in: model))
        let copies = try copyFolders(named: name, besides: folder)
        #expect(copies.count == 1)
        #expect(model.isPickingAgentForOpenedFiles)

        model.cancelOpenedFiles()

        #expect(model.openedFiles.isEmpty)
        #expect(!model.isPickingAgentForOpenedFiles)
        #expect(copies.allSatisfy { !exists($0) })
        #expect(exists(zip))
        await model.sendOpenedFiles(to: ChatID(1))
        #expect(sentDocuments(of: harness).isEmpty)
        #expect(sentPhotos(of: harness).isEmpty)
    }

    @Test func aFolderIsTurnedDownAndTheSheetSaysWhyUntilCancel() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let reports = folder.appending(path: "reports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: false)
        let harness = twoBots()
        let model = harness.model
        #expect(await harness.startAndLoadChats())

        model.openFile(at: reports)

        #expect(await eventually { model.openedFileError != nil })
        #expect(model.openedFileError == "Winston can send files, but not folders.")
        #expect(model.openedFiles.isEmpty)
        #expect(model.openedFilesBeingCopied == 0)
        #expect(model.isPickingAgentForOpenedFiles)
        await model.sendOpenedFiles(to: ChatID(1))
        #expect(sentDocuments(of: harness).isEmpty)

        model.cancelOpenedFiles()

        #expect(model.openedFileError == nil)
        #expect(!model.isPickingAgentForOpenedFiles)
        #expect(exists(reports))
    }

    @Test func theSystemsCopyInTheInboxIsRemovedOnceWinstonHasItsOwn() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let inbox = folder.appending(path: "Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: false)
        let name = "inbox-\(UUID().uuidString).zip"
        let systemCopy = try writeFile(name, Data("zip bytes".utf8), in: inbox)
        let harness = twoBots(inbox: inbox)
        let model = harness.model

        model.openFile(at: systemCopy)

        #expect(await copied(1, in: model))
        #expect(!exists(systemCopy))
        #expect(exists(inbox))
        let copies = try copyFolders(named: name, besides: inbox)
        defer { copies.forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(copies.count == 1)
        #expect(try Data(contentsOf: try #require(copies.first).appending(path: name)) == Data("zip bytes".utf8))
    }

    @Test func aFileOutsideTheInboxStays() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let inbox = folder.appending(path: "Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: false)
        let zip = try writeFile("logs.zip", Data("zip bytes".utf8), in: folder)
        let harness = twoBots(inbox: inbox)
        let model = harness.model

        model.openFile(at: zip)

        #expect(await copied(1, in: model))
        #expect(exists(zip))
        model.cancelOpenedFiles()
    }

    @Test func withNoAgentsTheSheetShowsAndCancelCloses() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = try writeFile("logs.zip", Data("zip bytes".utf8), in: folder)
        // Logged in, with no bot chats.
        let harness = Harness()
        let model = harness.model
        #expect(await harness.startAndLoadChats())

        model.openFile(at: zip)

        #expect(await copied(1, in: model))
        #expect(model.chats.isEmpty)
        #expect(model.isPickingAgentForOpenedFiles)
        await model.sendOpenedFiles(to: ChatID(1))
        #expect(sentDocuments(of: harness).isEmpty)
        #expect(model.openedFiles.count == 1)
        model.cancelOpenedFiles()
        #expect(!model.isPickingAgentForOpenedFiles)
    }

    @Test func aChatThatIsNotABotChatGetsNothing() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = try writeFile("logs.zip", Data("zip bytes".utf8), in: folder)
        let harness = twoBots()
        let model = harness.model
        #expect(await harness.startAndLoadChats())
        model.openFile(at: zip)
        #expect(await copied(1, in: model))

        await model.sendOpenedFiles(to: ChatID(99))

        #expect(sentDocuments(of: harness).isEmpty)
        #expect(model.openedFiles.count == 1)
        model.cancelOpenedFiles()
    }

    @Test func aWebLinkIsIgnored() async throws {
        let harness = twoBots()
        let model = harness.model
        #expect(await harness.startAndLoadChats())

        model.openFile(at: try #require(URL(string: "https://example.com/logs.zip")))

        #expect(model.openedFileCount == 0)
        #expect(model.openedFilesBeingCopied == 0)
        #expect(model.openedFiles.isEmpty)
        #expect(model.openedFileError == nil)
        #expect(!model.isPickingAgentForOpenedFiles)
    }
}

/// The folders in the temporary folder holding a file named `name`, other than `folder`: the copies
/// Winston made. Give the file a name no other test uses, since the tests run side by side.
private func copyFolders(named name: String, besides folder: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: URL.temporaryDirectory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent != folder.lastPathComponent && exists($0.appending(path: name)) }
}
