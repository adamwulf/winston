import CoreTransferable
import Foundation
import Testing
import TelegramLink
import TelegramLinkTestSupport
import VoiceLoop
import VoiceLoopTestSupport
import WinstonCore

/// Imports `url` the way SwiftUI imports a file dropped on the window: through an item provider.
private func drop(_ url: URL) async throws -> DroppedFile {
    try await drop(try #require(NSItemProvider(contentsOf: url)))
}

private func drop(_ provider: NSItemProvider) async throws -> DroppedFile {
    try await withCheckedThrowingContinuation { continuation in
        _ = provider.loadTransferable(type: DroppedFile.self) { continuation.resume(with: $0) }
    }
}

/// The documents TDLib was asked to send, in order.
@MainActor
private func sentDocuments(of harness: Harness) -> [(chatID: Int64?, path: String, caption: String?, disableContentTypeDetection: Bool)] {
    harness.fake.requests.compactMap { request in
        guard case .sendDocument(let chatID, let path, let caption, let disableContentTypeDetection) = request else {
            return nil
        }
        return (chatID, path, caption, disableContentTypeDetection)
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

/// Sending files dropped on the window: each copied under its own name as it's dropped, then handed
/// to TDLib as a document of its own.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SendDroppedFilesTests {
    @Test func droppedFilesAreSentInOrderAsCopiesUnderTheirOwnNamesWithTheCaptionOnTheFirst() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let monday = try writeFile("monday report.txt", "All 214 tests passed.", in: folder)
        let tuesday = try writeFile("tuesday.log", "2 tests failed.", in: folder)
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let files = [try await drop(monday), try await drop(tuesday)]
        harness.fake.hold(.sendMessage)

        let send = Task { await model.sendDroppedFiles(files, caption: "This week's runs.") }

        #expect(await eventually { !sentDocuments(of: harness).isEmpty })
        #expect(model.isSendingAttachment)
        harness.fake.release(.sendMessage)
        #expect(await send.value)
        #expect(!model.isSendingAttachment)

        let sent = sentDocuments(of: harness)
        let copies = sent.map { URL(filePath: $0.path) }
        defer { copies.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }
        #expect(sent.map(\.chatID) == [1, 1])
        #expect(sent.map(\.caption) == ["This week's runs.", nil])
        #expect(sent.map(\.disableContentTypeDetection) == [true, true])
        // Copies in folders of their own in the temporary folder, so TDLib can read them after the drop is over.
        #expect(copies.map(\.lastPathComponent) == ["monday report.txt", "tuesday.log"])
        for copy in copies {
            #expect(copy.deletingLastPathComponent().deletingLastPathComponent().pathComponents
                == URL.temporaryDirectory.pathComponents)
        }
        #expect(try Data(contentsOf: copies[0]) == Data("All 214 tests passed.".utf8))
        #expect(try Data(contentsOf: copies[1]) == Data("2 tests failed.".utf8))
        #expect(exists(monday))
        #expect(exists(tuesday))
        #expect(model.errorMessage == nil)
    }

    @Test func withAnEmptyCaptionNoneHasACaption() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let file = try await drop(try writeFile("report.txt", "All 214 tests passed.", in: folder))

        #expect(await model.sendDroppedFiles([file], caption: ""))

        let sent = try #require(sentDocuments(of: harness).last)
        try? FileManager.default.removeItem(at: URL(filePath: sent.path).deletingLastPathComponent())
        #expect(sent.caption == nil)
    }

    @Test func aDroppedFolderIsNotSentAndTheErrorSaysWhy() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let reports = folder.appending(path: "reports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: false)
        try Data("Monday".utf8).write(to: reports.appending(path: "monday.txt"))
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let requests = harness.fake.requests.count

        #expect(await model.sendDroppedFiles([try await drop(reports)], caption: "") == false)

        #expect(model.errorMessage == "Winston can send files, but not folders.")
        #expect(harness.fake.requests.count == requests)
    }

    @Test func aDroppedWebLinkIsNotSentAndShowsAnError() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let requests = harness.fake.requests.count
        let link = try await drop(NSItemProvider(object: try #require(URL(string: "https://example.com/report.txt")) as NSURL))

        #expect(await model.sendDroppedFiles([link], caption: "") == false)

        #expect(model.errorMessage != nil)
        #expect(harness.fake.requests.count == requests)
    }

    @Test func whenAFileCannotBeCopiedNoneIsSentTheErrorNamesItAndTheOtherCopiesAreRemoved() async throws {
        let folder = try makeTemporaryFolder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.appending(path: "secret.txt").path(percentEncoded: false))
            try? FileManager.default.removeItem(at: folder)
        }
        let report = try writeFile("report-\(UUID().uuidString).txt", "All 214 tests passed.", in: folder)
        let secret = try writeFile("secret.txt", "Unreadable.", in: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secret.path(percentEncoded: false))
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let requests = harness.fake.requests.count
        let files = [try await drop(report), try await drop(secret)]
        let reportCopyFolders = try copyFolders(of: report)
        #expect(reportCopyFolders.count == 1)

        #expect(await model.sendDroppedFiles(files, caption: "") == false)

        #expect(model.errorMessage?.contains("secret.txt") == true)
        #expect(!model.isSendingAttachment)
        #expect(harness.fake.requests.count == requests)
        // Nothing will upload the copy of the readable file, so it and its folder are gone.
        #expect(reportCopyFolders.allSatisfy { !exists($0) })
        #expect(exists(report))
    }

    @Test func whenTDLibRefusesADocumentTheRestAreNotSentAndTheirCopiesAreRemoved() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let harness = Harness.withTwoBots()
        harness.fake.fail(.sendMessage, code: 400, message: "FILE_PARTS_INVALID")
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let monday = try writeFile("monday-\(UUID().uuidString).txt", "Monday", in: folder)
        let tuesday = try writeFile("tuesday-\(UUID().uuidString).txt", "Tuesday", in: folder)
        let files = [try await drop(monday), try await drop(tuesday)]
        let copies = try copyFolders(of: monday) + copyFolders(of: tuesday)
        #expect(copies.count == 2)

        #expect(await model.sendDroppedFiles(files, caption: "") == false)

        #expect(sentDocuments(of: harness).map { URL(filePath: $0.path).lastPathComponent } == [monday.lastPathComponent])
        #expect(model.errorMessage == "FILE_PARTS_INVALID")
        #expect(!model.isSendingAttachment)
        // Nothing will upload either copy, so both are gone.
        #expect(copies.allSatisfy { !exists($0) })
    }

    @Test func withNoChatChosenNothingIsSentAndTheCopiesAreRemoved() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let harness = Harness()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let requests = harness.fake.requests.count
        let report = try writeFile("report-\(UUID().uuidString).txt", "All 214 tests passed.", in: folder)
        let file = try await drop(report)
        let reportCopyFolders = try copyFolders(of: report)
        #expect(reportCopyFolders.count == 1)

        #expect(await model.sendDroppedFiles([file], caption: "") == false)

        #expect(!model.isSendingAttachment)
        #expect(model.errorMessage == nil)
        #expect(harness.fake.requests.count == requests)
        #expect(reportCopyFolders.allSatisfy { !exists($0) })
    }

    @Test func anEmptyDropSendsNothing() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let requests = harness.fake.requests.count

        #expect(await model.sendDroppedFiles([], caption: "Nothing here.") == false)

        #expect(harness.fake.requests.count == requests)
        #expect(model.errorMessage == nil)
    }
}
