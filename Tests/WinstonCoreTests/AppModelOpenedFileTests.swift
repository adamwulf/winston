import Foundation
import Testing
import TelegramLink
import TelegramLinkTestSupport
import UniformTypeIdentifiers
import VoiceLoop
import VoiceLoopTestSupport
import WinstonCore

/// Home (chat 1) and Laptop (chat 2), as `Harness.withTwoBots()` has them, on an account that may
/// not be logged in yet, with `inboxes` standing in for iOS's.
@MainActor
private func twoBots(isLoggedIn: Bool = true, inboxes: [URL] = []) -> Harness {
    let fake = FakeTDLib(isLoggedIn: isLoggedIn)
    fake.addBotChat(id: 2, title: "Laptop", username: "laptop_bot")
    fake.addBotChat(id: 1, title: "Home", username: "home_bot")
    return Harness(fake: fake, openedFileInboxes: inboxes)
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

/// The temporary ID of the newest message still pending in `chat`, once the model shows one.
@MainActor
private func pendingMessageID(in chat: Int64, of model: AppModel) async -> Int64? {
    _ = await eventually { model.messages[ChatID(chat)]?.contains { $0.sendState == .pending } == true }
    return model.messages[ChatID(chat)]?.last { $0.sendState == .pending }?.id.rawValue
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

/// A name no other test uses, since the tests run side by side and `copyFolders(named:besides:)`
/// looks through the whole temporary folder.
private func uniqueName(_ name: String, _ type: String) -> String {
    "\(name)-\(UUID().uuidString).\(type)"
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

/// The folders in the temporary folder holding a file named `name`, other than `folder`: the copies
/// Winston made. Give the file a name no other test uses (`uniqueName`).
private func copyFolders(named name: String, besides folder: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: URL.temporaryDirectory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent != folder.lastPathComponent && exists($0.appending(path: name)) }
}

/// Holds a coordinated write on a file until `release()`, so a coordinated read of it, as
/// `DocumentFiles.copyForSending` makes, waits meanwhile: as for an iCloud Drive file still
/// downloading.
private final class WriteHold: Sendable {
    private let released = DispatchSemaphore(value: 0)

    init(on url: URL) throws {
        let started = DispatchSemaphore(value: 0)
        let released = released
        DispatchQueue.global().async {
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &error) { _ in
                started.signal()
                released.wait()
            }
        }
        try #require(started.wait(timeout: .now() + 10) == .success)
    }

    func release() {
        released.signal()
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
        let copy = URL(filePath: try #require(sent.first).path)
        #expect(copy.lastPathComponent == "logs.zip")
        #expect(try Data(contentsOf: copy) == Data("zip bytes".utf8))
        #expect(sentPhotos(of: harness).isEmpty)
        #expect(model.openedFiles.isEmpty)
        #expect(!model.isPickingAgentForOpenedFiles)
        #expect(model.openedFilesSendingTo == nil)
        #expect(model.currentChat?.id == ChatID(1))

        let pending = try #require(await pendingMessageID(in: 2, of: model))
        harness.fake.confirmSend(of: pending, in: 2, as: 500)
        #expect(await eventually { model.messages[ChatID(2)]?.last?.id == MessageID(500) })

        // The sent document's file, so it stays, as the + button's copies do.
        #expect(exists(copy))
        // Adam's own file, outside the inboxes, stays.
        #expect(exists(zip))
        #expect(model.openedFiles.isEmpty)
        #expect(model.openedFileError == nil)
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

    @Test func aStillImageGoesAsAPhotoAndWinstonsCopyGoesOnceItIsSent() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = uniqueName("Screenshot", "png")
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
        let jpeg = URL(filePath: try #require(sent.first).path)
        #expect(try imageFileInfo(at: jpeg) == ImageFileInfo(type: UTType.jpeg.identifier, width: 40, height: 20))
        #expect(sentDocuments(of: harness).isEmpty)
        #expect(model.openedFiles.isEmpty)
        // Kept until TDLib says the photo was sent, in case it isn't.
        #expect(copyFolders.allSatisfy(exists))

        let pending = try #require(await pendingMessageID(in: 1, of: model))
        harness.fake.confirmSend(of: pending, in: 1, as: 500)

        #expect(await eventually { copyFolders.allSatisfy { !exists($0) } })
        // The sent photo's file.
        #expect(exists(jpeg))
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

    @Test func filesGoInTheOrderTheyWereOpenedThoughALaterOneIsCopiedFirst() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let notes = try writeFile("notes.txt", Data("hello".utf8), in: folder)
        let photo = try writeFile("photo.jpg", try imageData(width: 40, height: 30, type: .jpeg), in: folder)
        let harness = twoBots()
        let model = harness.model
        #expect(await harness.startAndLoadChats())
        // The notes are slow to copy, as an iCloud Drive file still downloading.
        let hold = try WriteHold(on: notes)
        defer { hold.release() }

        model.openFile(at: notes)
        model.openFile(at: photo)

        #expect(await eventually { model.openedFiles.last?.isCopied == true })
        #expect(model.openedFiles.map(\.name) == ["notes.txt", "photo.jpg"])
        #expect(model.openedFiles.map(\.isCopied) == [false, true])
        #expect(model.openedFilesBeingCopied == 1)
        #expect(model.openedFileCount == 2)
        #expect(model.isPickingAgentForOpenedFiles)
        // Nothing goes until both are copied.
        await model.sendOpenedFiles(to: ChatID(2))
        #expect(sentDocuments(of: harness).isEmpty)
        #expect(sentPhotos(of: harness).isEmpty)

        hold.release()
        #expect(await copied(2, in: model))
        #expect(model.openedFiles.map(\.name) == ["notes.txt", "photo.jpg"])
        await model.sendOpenedFiles(to: ChatID(2))

        let documents = sentDocuments(of: harness)
        let photos = sentPhotos(of: harness)
        defer {
            removeDocumentCopies(documents.map(\.path))
            photos.forEach { try? FileManager.default.removeItem(at: URL(filePath: $0.path)) }
        }
        #expect(documents.map(\.chatID) == [2])
        #expect(photos.map(\.chatID) == [2])
        let sends = harness.fake.requests.compactMap { request -> String? in
            switch request {
            case .sendDocument: "document"
            case .sendPhoto: "photo"
            default: nil
            }
        }
        #expect(sends == ["document", "photo"])
        #expect(model.openedFiles.isEmpty)
    }

    @Test func aSendTDLibTurnsDownKeepsTheFileWithAnErrorNamingTheAgentForAnotherPick() async throws {
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
        #expect(model.openedFileError == "Couldn't send logs.zip to Home: FILE_PARTS_INVALID")
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

    @Test func aPhotoTDLibTurnsDownLeavesNoJPEGBehindAndKeepsItsCopy() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = uniqueName("Screenshot", "png")
        let png = try writeFile(name, try imageData(width: 40, height: 20), in: folder)
        let harness = twoBots()
        let model = harness.model
        #expect(await harness.startAndLoadChats())
        model.openFile(at: png)
        #expect(await copied(1, in: model))
        let copyFolders = try copyFolders(named: name, besides: folder)
        harness.fake.fail(.sendMessage, code: 400, message: "PHOTO_INVALID_DIMENSIONS")

        await model.sendOpenedFiles(to: ChatID(1))

        let refused = try #require(sentPhotos(of: harness).first)
        #expect(!exists(URL(filePath: refused.path)))
        #expect(copyFolders.count == 1)
        #expect(copyFolders.allSatisfy(exists))
        #expect(model.openedFileError == "Couldn't send \(name) to Home: PHOTO_INVALID_DIMENSIONS")
        #expect(model.openedFiles.count == 1)

        // Cancel removes the copy, and there is no JPEG left to remove.
        model.cancelOpenedFiles()
        #expect(copyFolders.allSatisfy { !exists($0) })
        #expect(exists(png))
    }

    @Test func anUploadThatFailsLaterBringsTheFileBackWithAnErrorNamingTheAgent() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = try writeFile("logs.zip", Data("zip bytes".utf8), in: folder)
        let harness = twoBots()
        let model = harness.model
        #expect(await harness.startAndLoadChats())
        model.openFile(at: zip)
        #expect(await copied(1, in: model))
        let file = try #require(model.openedFiles.first)
        // Laptop, while Home is the chat shown, so the failed message isn't on screen.
        await model.sendOpenedFiles(to: ChatID(2))
        #expect(model.openedFiles.isEmpty)
        #expect(!model.isPickingAgentForOpenedFiles)

        let pending = try #require(await pendingMessageID(in: 2, of: model))
        harness.fake.failSend(of: pending, in: 2, code: 500, message: "UPLOAD_FAILED")

        #expect(await eventually { model.isPickingAgentForOpenedFiles })
        #expect(model.openedFiles == [file])
        #expect(model.openedFileError == "Couldn't send logs.zip to Laptop: UPLOAD_FAILED")
        #expect(model.currentChat?.id == ChatID(1))
        // Its copy stays, for another try.
        let copy = URL(filePath: try #require(sentDocuments(of: harness).first).path)
        defer { removeDocumentCopies([copy.path(percentEncoded: false)]) }
        #expect(exists(copy))

        await model.sendOpenedFiles(to: ChatID(2))

        #expect(sentDocuments(of: harness).map(\.path) == [copy, copy].map { $0.path(percentEncoded: false) })
        #expect(model.openedFiles.isEmpty)
        #expect(model.openedFileError == nil)
    }

    @Test func aPhotoWhoseUploadFailsLaterLosesItsJPEGAndKeepsItsCopy() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = uniqueName("Screenshot", "png")
        let png = try writeFile(name, try imageData(width: 40, height: 20), in: folder)
        let harness = twoBots()
        let model = harness.model
        #expect(await harness.startAndLoadChats())
        model.openFile(at: png)
        #expect(await copied(1, in: model))
        let copyFolders = try copyFolders(named: name, besides: folder)
        await model.sendOpenedFiles(to: ChatID(2))
        let jpeg = URL(filePath: try #require(sentPhotos(of: harness).first).path)
        #expect(exists(jpeg))

        let pending = try #require(await pendingMessageID(in: 2, of: model))
        harness.fake.failSend(of: pending, in: 2, code: 500, message: "UPLOAD_FAILED")

        #expect(await eventually { model.openedFiles.count == 1 })
        #expect(!exists(jpeg))
        #expect(copyFolders.count == 1)
        #expect(copyFolders.allSatisfy(exists))
        #expect(model.openedFileError == "Couldn't send \(name) to Laptop: UPLOAD_FAILED")
        model.cancelOpenedFiles()
        #expect(copyFolders.allSatisfy { !exists($0) })
    }

    @Test func cancelRemovesWinstonsCopyAndSendsNothing() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = uniqueName("cancelled", "zip")
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

    @Test func aCopyFinishedAfterCancelIsRemoved() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = uniqueName("slow", "zip")
        let zip = try writeFile(name, Data("zip bytes".utf8), in: folder)
        let harness = twoBots()
        let model = harness.model
        #expect(await harness.startAndLoadChats())
        let hold = try WriteHold(on: zip)
        defer { hold.release() }
        model.openFile(at: zip)
        #expect(model.openedFilesBeingCopied == 1)

        model.cancelOpenedFiles()
        #expect(model.openedFiles.isEmpty)
        hold.release()

        // The copy is made, then removed, and the file doesn't come back.
        try await settle()
        #expect(try copyFolders(named: name, besides: folder).isEmpty)
        #expect(model.openedFiles.isEmpty)
        #expect(!model.isPickingAgentForOpenedFiles)
        #expect(exists(zip))
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
        #expect(model.isPickingAgentForOpenedFiles)
        await model.sendOpenedFiles(to: ChatID(1))
        #expect(sentDocuments(of: harness).isEmpty)

        model.cancelOpenedFiles()

        #expect(model.openedFileError == nil)
        #expect(!model.isPickingAgentForOpenedFiles)
        #expect(exists(reports))
    }

    @Test func theFileIOSHandedOverStaysUntilItIsSent() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // As Documents/Inbox and tmp/<bundle ID>-Inbox; this one comes in the second.
        let inboxes = ["Inbox", "com.example.winston-Inbox"].map {
            folder.appending(path: $0, directoryHint: .isDirectory)
        }
        for inbox in inboxes {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: false)
        }
        let unrelated = try writeFile("other.txt", Data("not opened".utf8), in: inboxes[1])
        let systemCopy = try writeFile("logs.zip", Data("zip bytes".utf8), in: inboxes[1])
        let harness = twoBots(inboxes: inboxes)
        let model = harness.model
        #expect(await harness.startAndLoadChats())

        model.openFile(at: systemCopy)
        #expect(await copied(1, in: model))
        #expect(exists(systemCopy))
        await model.sendOpenedFiles(to: ChatID(1))
        let sent = sentDocuments(of: harness)
        defer { removeDocumentCopies(sent.map(\.path)) }
        // Not yet: the upload could still fail.
        #expect(exists(systemCopy))

        let pending = try #require(await pendingMessageID(in: 1, of: model))
        harness.fake.confirmSend(of: pending, in: 1, as: 500)

        #expect(await eventually { !exists(systemCopy) })
        #expect(exists(URL(filePath: try #require(sent.first).path)))
        // Only the file Winston was handed.
        #expect(exists(unrelated))
        #expect(inboxes.allSatisfy(exists))
    }

    @Test func theFileIOSHandedOverGoesOnCancel() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let inbox = folder.appending(path: "Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: false)
        let name = uniqueName("inbox", "zip")
        let systemCopy = try writeFile(name, Data("zip bytes".utf8), in: inbox)
        let harness = twoBots(inboxes: [inbox])
        let model = harness.model
        #expect(await harness.startAndLoadChats())
        model.openFile(at: systemCopy)
        #expect(await copied(1, in: model))
        let copies = try copyFolders(named: name, besides: folder)
        #expect(copies.count == 1)
        #expect(exists(systemCopy))

        model.cancelOpenedFiles()

        #expect(!exists(systemCopy))
        #expect(copies.allSatisfy { !exists($0) })
        #expect(exists(inbox))
    }

    @Test func aFileOutsideTheInboxesStaysOnceSent() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let inbox = folder.appending(path: "Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: false)
        let zip = try writeFile("logs.zip", Data("zip bytes".utf8), in: folder)
        let harness = twoBots(inboxes: [inbox])
        let model = harness.model
        #expect(await harness.startAndLoadChats())
        model.openFile(at: zip)
        #expect(await copied(1, in: model))
        await model.sendOpenedFiles(to: ChatID(1))
        let sent = sentDocuments(of: harness)
        defer { removeDocumentCopies(sent.map(\.path)) }

        let pending = try #require(await pendingMessageID(in: 1, of: model))
        harness.fake.confirmSend(of: pending, in: 1, as: 500)

        #expect(await eventually { model.messages[ChatID(1)]?.last?.id == MessageID(500) })
        #expect(exists(zip))
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
        #expect(model.openedFiles.isEmpty)
        #expect(model.openedFileError == nil)
        #expect(!model.isPickingAgentForOpenedFiles)
    }
}
