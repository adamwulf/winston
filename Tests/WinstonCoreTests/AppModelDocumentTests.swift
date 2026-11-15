import Foundation
import Testing
import TelegramLink
import TelegramLinkTestSupport
import VoiceLoop
import VoiceLoopTestSupport
import WinstonCore

/// The document TDLib was last asked to send, or nil if the last request wasn't one.
@MainActor
private func lastSentDocument(of harness: Harness) -> (chatID: Int64?, path: String, caption: String?, disableContentTypeDetection: Bool)? {
    guard case .sendDocument(let chatID, let path, let caption, let disableContentTypeDetection)? = harness.fake.requests.last else {
        return nil
    }
    return (chatID, path, caption, disableContentTypeDetection)
}

/// Sending a picked file: copied under its own name into the temporary folder, then handed to TDLib as a document.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SendDocumentTests {
    @Test func aFileIsSentAsADocumentCopiedUnderItsOwnNameWithNoCaptionWhenTheCaptionIsEmpty() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = folder.appending(path: "nightly-report.txt")
        try Data("All 214 tests passed.".utf8).write(to: report)
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        harness.fake.hold(.sendMessage)

        let send = Task { await model.sendDocuments(caption: "", fileURLs: [report]) }

        #expect(await eventually { lastSentDocument(of: harness) != nil })
        #expect(model.isSendingAttachment)
        harness.fake.release(.sendMessage)
        #expect(await send.value)
        #expect(!model.isSendingAttachment)

        let sent = try #require(lastSentDocument(of: harness))
        let copy = URL(filePath: sent.path)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        #expect(sent.chatID == 1)
        #expect(sent.caption == nil)
        #expect(sent.disableContentTypeDetection)
        // A copy in a folder of its own in the temporary folder, so TDLib can read it after the picker's access ends.
        #expect(copy.lastPathComponent == "nightly-report.txt")
        #expect(copy.deletingLastPathComponent().deletingLastPathComponent().pathComponents
            == URL.temporaryDirectory.pathComponents)
        #expect(try Data(contentsOf: copy) == Data("All 214 tests passed.".utf8))
        #expect(FileManager.default.fileExists(atPath: report.path(percentEncoded: false)))
        // The pending message shows the document being uploaded, named as the picked file is.
        #expect(await eventually {
            model.currentMessages.last?.attachment
                == .document(FileRef(id: 1, localPath: sent.path), fileName: "nightly-report.txt", mimeType: "", size: 0)
        })
        #expect(model.currentMessages.last?.sendState == .pending)
        #expect(model.errorMessage == nil)
    }

    @Test func aCaptionIsSentAsGiven() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = folder.appending(path: "nightly-report.txt")
        try Data("All 214 tests passed.".utf8).write(to: report)
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model

        #expect(await model.sendDocuments(caption: "Last night's run.", fileURLs: [report]))

        let sent = try #require(lastSentDocument(of: harness))
        try? FileManager.default.removeItem(at: URL(filePath: sent.path).deletingLastPathComponent())
        #expect(sent.chatID == 1)
        #expect(sent.caption == "Last night's run.")
    }

    @Test func aFileThatCannotBeReadIsNotSentAndTheErrorNamesIt() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let requests = harness.fake.requests.count

        #expect(await model.sendDocuments(caption: "", fileURLs: [folder.appending(path: "gone.txt")]) == false)

        #expect(model.errorMessage?.contains("gone.txt") == true)
        #expect(!model.isSendingAttachment)
        #expect(harness.fake.requests.count == requests)
    }

    @Test func aDocumentTDLibRefusesShowsTheErrorAndRemovesTheCopy() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = folder.appending(path: "nightly-report.txt")
        try Data("All 214 tests passed.".utf8).write(to: report)
        let harness = Harness.withTwoBots()
        harness.fake.fail(.sendMessage, code: 400, message: "FILE_PARTS_INVALID")
        #expect(await harness.startAndLoadChats())
        let model = harness.model

        #expect(await model.sendDocuments(caption: "", fileURLs: [report]) == false)

        let sent = try #require(lastSentDocument(of: harness))
        let copyFolder = URL(filePath: sent.path).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: copyFolder) }
        #expect(model.errorMessage == "FILE_PARTS_INVALID")
        #expect(!model.isSendingAttachment)
        // Nothing will upload it, so the copy and its folder are gone; the picked file stays.
        #expect(!FileManager.default.fileExists(atPath: copyFolder.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: report.path(percentEncoded: false)))
    }

    @Test func withNoChatChosenNothingIsSent() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = folder.appending(path: "nightly-report.txt")
        try Data("All 214 tests passed.".utf8).write(to: report)
        let harness = Harness()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let requests = harness.fake.requests.count

        #expect(await model.sendDocuments(caption: "", fileURLs: [report]) == false)

        #expect(!model.isSendingAttachment)
        #expect(model.errorMessage == nil)
        #expect(harness.fake.requests.count == requests)
    }
}

/// The documents TDLib was asked to send, in order.
@MainActor
private func sentDocuments(of harness: Harness) -> [(chatID: Int64?, path: String, caption: String?)] {
    harness.fake.requests.compactMap { request in
        guard case .sendDocument(let chatID, let path, let caption, _) = request else { return nil }
        return (chatID, path, caption)
    }
}

/// Writes `text` to a file named `name` in `folder`, and returns the file.
private func writeFile(_ name: String, _ text: String, in folder: URL) throws -> URL {
    let file = folder.appending(path: name)
    try Data(text.utf8).write(to: file)
    return file
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
}

/// The folders in the temporary folder holding a file named as `file` is, other than its own: the
/// copies made of it. Give `file` a name no other test uses, since the tests run side by side.
private func copyFolders(of file: URL) throws -> [URL] {
    let ownFolder = file.deletingLastPathComponent().lastPathComponent
    return try FileManager.default.contentsOfDirectory(at: URL.temporaryDirectory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent != ownFolder && exists($0.appending(path: file.lastPathComponent)) }
}

/// Sending several files at once, as when they're dropped on the window: one document each, in order.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SendSeveralDocumentsTests {
    @Test func theyAreSentInOrderUnderTheirOwnNamesWithTheCaptionOnTheFirst() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let monday = try writeFile("monday report.txt", "All 214 tests passed.", in: folder)
        let tuesday = try writeFile("tuesday.log", "2 tests failed.", in: folder)
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model

        #expect(await model.sendDocuments(caption: "This week's runs.", fileURLs: [monday, tuesday]))

        let sent = sentDocuments(of: harness)
        let copies = sent.map { URL(filePath: $0.path) }
        defer { copies.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }
        try #require(copies.count == 2)
        #expect(sent.map(\.chatID) == [1, 1])
        #expect(sent.map(\.caption) == ["This week's runs.", nil])
        #expect(copies.map(\.lastPathComponent) == ["monday report.txt", "tuesday.log"])
        #expect(try Data(contentsOf: copies[0]) == Data("All 214 tests passed.".utf8))
        #expect(try Data(contentsOf: copies[1]) == Data("2 tests failed.".utf8))
        #expect(!model.isSendingAttachment)
        #expect(model.errorMessage == nil)
    }

    @Test func aFolderIsNotSentAndTheErrorSaysWhy() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let reports = folder.appending(path: "reports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: false)
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let requests = harness.fake.requests.count

        #expect(await model.sendDocuments(caption: "", fileURLs: [reports]) == false)

        #expect(model.errorMessage == "Winston can send files, but not folders.")
        #expect(harness.fake.requests.count == requests)
    }

    @Test func aWebLinkIsNotSentAndShowsAnError() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let requests = harness.fake.requests.count

        let link = try #require(URL(string: "https://example.com/report.txt"))
        #expect(await model.sendDocuments(caption: "", fileURLs: [link]) == false)

        #expect(model.errorMessage != nil)
        #expect(harness.fake.requests.count == requests)
    }

    @Test func whenOneCannotBeCopiedNoneIsSentAndTheCopiesMadeAreRemoved() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = try writeFile("report-\(UUID().uuidString).txt", "All 214 tests passed.", in: folder)
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let requests = harness.fake.requests.count

        #expect(await model.sendDocuments(caption: "Both.", fileURLs: [report, folder.appending(path: "gone.txt")]) == false)

        #expect(model.errorMessage?.contains("gone.txt") == true)
        #expect(!model.isSendingAttachment)
        #expect(harness.fake.requests.count == requests)
        // Nothing will upload the copy of the first file, so it and its folder are gone.
        #expect(try copyFolders(of: report).isEmpty)
        #expect(exists(report))
    }

    @Test func whenTDLibTurnsDownALaterOneTheCaptionCountsAsSentAndTheUnsentCopiesAreRemoved() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try ["monday", "tuesday", "wednesday"].map {
            try writeFile("\($0)-\(UUID().uuidString).txt", $0, in: folder)
        }
        let harness = Harness.withTwoBots()
        harness.fake.fail(.sendMessage, code: 400, message: "FILE_PARTS_INVALID", afterSucceeding: 1)
        #expect(await harness.startAndLoadChats())
        let model = harness.model

        // True: the first file, which carries the caption, was sent.
        #expect(await model.sendDocuments(caption: "This week's runs.", fileURLs: files))

        let sent = sentDocuments(of: harness)
        // Wednesday's was never tried.
        #expect(sent.map { URL(filePath: $0.path).lastPathComponent } == [files[0].lastPathComponent, files[1].lastPathComponent])
        #expect(sent.first?.caption == "This week's runs.")
        let mondayCopy = URL(filePath: try #require(sent.first).path)
        defer { try? FileManager.default.removeItem(at: mondayCopy.deletingLastPathComponent()) }
        #expect(model.errorMessage == "FILE_PARTS_INVALID")
        #expect(!model.isSendingAttachment)
        // Monday's copy stays for TDLib to upload; nothing will upload the other two.
        #expect(exists(mondayCopy))
        #expect(try copyFolders(of: files[1]).isEmpty)
        #expect(try copyFolders(of: files[2]).isEmpty)
    }

    @Test func noFilesSendsNothing() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let requests = harness.fake.requests.count

        #expect(await model.sendDocuments(caption: "Nothing here.", fileURLs: []) == false)

        #expect(harness.fake.requests.count == requests)
        #expect(model.errorMessage == nil)
    }
}
