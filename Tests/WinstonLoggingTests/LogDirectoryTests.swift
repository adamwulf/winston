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

    #if os(macOS)
    /// Without an override it resolves the user's real Library, so it runs in an exit test's child
    /// process with the home folder moved to a temporary one. macOS only: iOS has no exit tests.
    @Test
    func withoutAnOverrideResolvesLogsWinstonUnderTheLibraryAndCreatesIt() async {
        await #expect(processExitsWith: .success) {
            let home = try TemporaryFolder()
            defer { home.remove() }
            let library = try home.becomeTheHomeFolder()

            let logs = try LogDirectory.logsDirectoryURL()

            let expected = library.appending(path: "Logs/Winston", directoryHint: .isDirectory)
            #expect(logs.standardizedFileURL == expected.standardizedFileURL)
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: expected.path(percentEncoded: false), isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }
    #endif

    @Test
    func libraryUnavailableSaysSo() {
        #expect(LogDirectory.Failure.libraryDirectoryUnavailable.localizedDescription == "The Library folder isn't available.")
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

    /// Makes this folder Foundation's home folder for the rest of the process, and returns the
    /// `Library` folder `FileManager` now resolves: `<this folder>/Library`. It throws, through
    /// `#require`, if the Library folder isn't inside this one, so a caller never goes on to code
    /// that would use the real `~/Library`.
    ///
    /// Process-wide and permanent: call it only in an exit test's child process.
    func becomeTheHomeFolder() throws -> URL {
        try #require(setenv("CFFIXED_USER_HOME", url.path(percentEncoded: false), 1) == 0)
        let library = try #require(FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first)
        let expected = url.appending(path: "Library", directoryHint: .isDirectory)
        try #require(
            library.standardizedFileURL == expected.standardizedFileURL,
            "the home folder didn't move: Library is \(library.path(percentEncoded: false))"
        )
        return library
    }
}
