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

        let send = Task { await model.sendDocument(caption: "", fileURL: report) }

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

        #expect(await model.sendDocument(caption: "Last night's run.", fileURL: report))

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

        #expect(await model.sendDocument(caption: "", fileURL: folder.appending(path: "gone.txt")) == false)

        #expect(model.errorMessage?.contains("gone.txt") == true)
        #expect(!model.isSendingAttachment)
        #expect(harness.fake.requests.count == requests)
    }

    @Test func aDocumentTDLibRefusesShowsTheError() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = folder.appending(path: "nightly-report.txt")
        try Data("All 214 tests passed.".utf8).write(to: report)
        let harness = Harness.withTwoBots()
        harness.fake.fail(.sendMessage, code: 400, message: "FILE_PARTS_INVALID")
        #expect(await harness.startAndLoadChats())
        let model = harness.model

        #expect(await model.sendDocument(caption: "", fileURL: report) == false)

        let sent = try #require(lastSentDocument(of: harness))
        try? FileManager.default.removeItem(at: URL(filePath: sent.path).deletingLastPathComponent())
        #expect(model.errorMessage == "FILE_PARTS_INVALID")
        #expect(!model.isSendingAttachment)
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

        #expect(await model.sendDocument(caption: "", fileURL: report) == false)

        #expect(!model.isSendingAttachment)
        #expect(model.errorMessage == nil)
        #expect(harness.fake.requests.count == requests)
    }
}
