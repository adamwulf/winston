import Foundation
import Testing
import WinstonLogging

@Suite("LogDirectory")
struct LogDirectoryTests {
    @Test
    func resolvesLogsWinstonUnderTheBaseOverrideAndCreatesIt() throws {
        let base = try TemporaryFolder()
        defer { base.remove() }

        let logs = try LogDirectory.logsDirectoryURL(baseOverride: base.url)

        #expect(logs.standardizedFileURL == base.url.appending(path: "Logs/Winston", directoryHint: .isDirectory).standardizedFileURL)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: logs.path(percentEncoded: false), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test
    func resolvingAgainKeepsTheFilesAlreadyThere() throws {
        let base = try TemporaryFolder()
        defer { base.remove() }
        let logs = try LogDirectory.logsDirectoryURL(baseOverride: base.url)
        let file = logs.appending(path: "app-2026-11-13.log")
        try Data("line\n".utf8).write(to: file)

        let again = try LogDirectory.logsDirectoryURL(baseOverride: base.url)

        #expect(again.standardizedFileURL == logs.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    @Test
    func aBaseThatIsAFileThrows() throws {
        let base = try TemporaryFolder()
        defer { base.remove() }
        let notAFolder = base.url.appending(path: "not-a-folder")
        try Data("x".utf8).write(to: notAFolder)

        #expect(throws: (any Error).self) {
            try LogDirectory.logsDirectoryURL(baseOverride: notAFolder)
        }
    }
}

/// A unique folder under the temporary directory, removed by `remove()`.
struct TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "WinstonLoggingTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
