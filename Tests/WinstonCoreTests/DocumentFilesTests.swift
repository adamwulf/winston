import Foundation
import Testing
import WinstonCore

/// Copying a picked file for sending as a document.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CopyForSendingTests {
    @Test func theCopyKeepsTheFilesNameAndContentsInAFolderOfItsOwnInTheTemporaryFolder() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = folder.appending(path: "nightly report.txt")
        try Data("All 214 tests passed.".utf8).write(to: report)

        let copy = try await DocumentFiles.copyForSending(from: report)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }

        #expect(copy.lastPathComponent == "nightly report.txt")
        #expect(copy.deletingLastPathComponent().deletingLastPathComponent().pathComponents
            == URL.temporaryDirectory.pathComponents)
        #expect(try Data(contentsOf: copy) == Data("All 214 tests passed.".utf8))
        #expect(FileManager.default.fileExists(atPath: report.path(percentEncoded: false)))
    }

    @Test func twoFilesWithTheSameNameGetSeparateCopies() async throws {
        let first = try makeTemporaryFolder()
        let second = try makeTemporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try Data("Monday".utf8).write(to: first.appending(path: "report.txt"))
        try Data("Tuesday".utf8).write(to: second.appending(path: "report.txt"))

        let firstCopy = try await DocumentFiles.copyForSending(from: first.appending(path: "report.txt"))
        let secondCopy = try await DocumentFiles.copyForSending(from: second.appending(path: "report.txt"))
        defer {
            try? FileManager.default.removeItem(at: firstCopy.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondCopy.deletingLastPathComponent())
        }

        #expect(firstCopy != secondCopy)
        #expect(try Data(contentsOf: firstCopy) == Data("Monday".utf8))
        #expect(try Data(contentsOf: secondCopy) == Data("Tuesday".utf8))
    }

    @Test func removingACopyRemovesItsFolderAndLeavesTheOriginal() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = folder.appending(path: "report.txt")
        try Data("Monday".utf8).write(to: report)
        let copy = try await DocumentFiles.copyForSending(from: report)
        let copyFolder = copy.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: copyFolder) }

        DocumentFiles.removeCopy(copy)

        #expect(!FileManager.default.fileExists(atPath: copyFolder.path(percentEncoded: false)))
        #expect(try Data(contentsOf: report) == Data("Monday".utf8))
    }

    @Test func aMissingFileThrows() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        await #expect(throws: CocoaError.self) {
            try await DocumentFiles.copyForSending(from: folder.appending(path: "gone.txt"))
        }
    }
}
