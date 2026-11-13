import Foundation
import Testing
@testable import WinstonLogging

@Suite("LogExporter")
struct LogExporterTests {
    @Test
    func zipsEveryFileInTheFolder() async throws {
        let base = try TemporaryFolder()
        defer { base.remove() }
        let logs = try LogDirectory.logsDirectoryURL(baseOverride: base.url)
        let names = ["app-2026-11-11.log", "app-2026-11-12.log", "app-2026-11-13.log"]
        for name in names {
            try Data("ts=1 msg=\"\(name)\"\n".utf8).write(to: logs.appending(path: name))
        }

        let zip = try await LogExporter.exportLogs(directoryOverride: logs, outputDirectory: base.exports)

        // Still there after the coordinator, which deletes its own zip when its block returns.
        #expect(FileManager.default.fileExists(atPath: zip.path(percentEncoded: false)))
        let data = try Data(contentsOf: zip)
        #expect(Array(data.prefix(4)) == [0x50, 0x4B, 0x03, 0x04], "a zip starts with PK\\x03\\x04")

        // The archive holds the folder itself, so entries are `Winston/<file>`. Finder-style zips
        // can add `__MACOSX/` entries for extended attributes; those aren't log files.
        let files = try zipEntryNames(data)
            .filter { !$0.hasPrefix("__MACOSX/") && !$0.hasSuffix("/") }
        #expect(Set(files) == Set(names.map { "Winston/\($0)" }))
    }

    @Test
    func zipIsNamedWithTheTimestamp() async throws {
        let base = try TemporaryFolder()
        defer { base.remove() }
        let logs = try LogDirectory.logsDirectoryURL(baseOverride: base.url)
        try Data("line\n".utf8).write(to: logs.appending(path: "app-2026-11-13.log"))
        let timestamp = Date(timeIntervalSince1970: 1_794_551_444)

        let zip = try await LogExporter.exportLogs(
            timestamp: timestamp,
            directoryOverride: logs,
            outputDirectory: base.exports
        )

        let name = zip.lastPathComponent
        #expect(name.wholeMatch(of: /Winston-Logs-\d{8}-\d{6}\.zip/) != nil, "unexpected name \(name)")
        #expect(name == LogExporter.archiveName(for: timestamp))
        #expect(zip.deletingLastPathComponent().standardizedFileURL == base.exports.standardizedFileURL)
    }

    @Test
    func archiveNameIsTheDateAndTimeInTheGivenZone() throws {
        let timestamp = Date(timeIntervalSince1970: 1_794_551_444) // 2026-11-13 06:30:44 UTC
        let utc = try #require(TimeZone(identifier: "UTC"))
        let chicago = try #require(TimeZone(identifier: "America/Chicago"))

        #expect(LogExporter.archiveName(for: timestamp, timeZone: utc) == "Winston-Logs-20261113-063044.zip")
        #expect(LogExporter.archiveName(for: timestamp, timeZone: chicago) == "Winston-Logs-20261113-003044.zip")
    }

    @Test
    func eachExportRemovesTheEarlierOnes() async throws {
        let base = try TemporaryFolder()
        defer { base.remove() }
        let logs = try LogDirectory.logsDirectoryURL(baseOverride: base.url)
        try Data("line\n".utf8).write(to: logs.appending(path: "app-2026-11-13.log"))
        let earlier = Date(timeIntervalSince1970: 1_794_551_444)
        let later = Date(timeIntervalSince1970: 1_794_551_500)

        let first = try await LogExporter.exportLogs(timestamp: earlier, directoryOverride: logs, outputDirectory: base.exports)
        let second = try await LogExporter.exportLogs(timestamp: later, directoryOverride: logs, outputDirectory: base.exports)

        #expect(!FileManager.default.fileExists(atPath: first.path(percentEncoded: false)))
        let left = try FileManager.default.contentsOfDirectory(atPath: base.exports.path(percentEncoded: false))
        #expect(left == [second.lastPathComponent])
    }

    @Test
    func exportingTwiceInOneSecondReplacesTheEarlierZip() async throws {
        let base = try TemporaryFolder()
        defer { base.remove() }
        let logs = try LogDirectory.logsDirectoryURL(baseOverride: base.url)
        try Data("line\n".utf8).write(to: logs.appending(path: "app-2026-11-13.log"))
        let timestamp = Date(timeIntervalSince1970: 1_794_551_444)

        let first = try await LogExporter.exportLogs(timestamp: timestamp, directoryOverride: logs, outputDirectory: base.exports)
        let second = try await LogExporter.exportLogs(timestamp: timestamp, directoryOverride: logs, outputDirectory: base.exports)

        #expect(first == second)
        #expect(FileManager.default.fileExists(atPath: second.path(percentEncoded: false)))
    }

    @Test
    func exportsGoToTheirOwnTemporaryFolderByDefault() {
        let folder = LogExporter.defaultOutputDirectory
        #expect(folder.lastPathComponent == "DebugLogExports")
        #expect(
            folder.deletingLastPathComponent().standardizedFileURL
                == FileManager.default.temporaryDirectory.standardizedFileURL
        )
    }
}

private extension TemporaryFolder {
    /// A folder for the test's zips, so parallel tests don't empty each other's.
    var exports: URL { url.appending(path: "Exports", directoryHint: .isDirectory) }
}

/// The entry names in a zip's central directory.
private func zipEntryNames(_ data: Data) throws -> [String] {
    let bytes = [UInt8](data)
    func uint16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
    func uint32(_ offset: Int) -> Int { uint16(offset) | uint16(offset + 2) << 16 }

    // The end-of-central-directory record is the last 22 bytes, plus any archive comment.
    let endSignature = 0x0605_4B50
    let end = try #require(
        bytes.count >= 22
            ? stride(from: bytes.count - 22, through: 0, by: -1).first { uint32($0) == endSignature }
            : nil,
        "no end-of-central-directory record"
    )
    let count = uint16(end + 10)
    var offset = uint32(end + 16)
    var names: [String] = []
    for _ in 0..<count {
        try #require(offset + 46 <= bytes.count && uint32(offset) == 0x0201_4B50, "bad central directory entry")
        let nameLength = uint16(offset + 28)
        let extraLength = uint16(offset + 30)
        let commentLength = uint16(offset + 32)
        names.append(String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self))
        offset += 46 + nameLength + extraLength + commentLength
    }
    return names
}
