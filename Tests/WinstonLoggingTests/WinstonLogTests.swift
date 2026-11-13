import Foundation
import Testing
import WinstonLogging

// macOS only: every test here needs an exit test's child process, and iOS has no exit tests.
#if os(macOS)
@Suite("WinstonLog")
struct WinstonLogTests {
    /// FellerBuncher's bootstrap is process-wide and permanent, so it runs in an exit test's child
    /// process. The shared test process never bootstraps, and its loggers keep swift-log's default
    /// stderr handler.
    @Test
    func bootstrapWritesTheDailyFileUnderLogsWinston() async {
        await #expect(processExitsWith: .success) {
            let base = try TemporaryFolder()
            defer { base.remove() }

            WinstonLog.bootstrap(baseOverride: base.url)
            // Idempotent: a second call must not reach LoggingSystem.bootstrap again, which traps.
            WinstonLog.bootstrap(baseOverride: base.url)
            let marker = UUID().uuidString
            Logger(label: "test.bootstrap").notice("bootstrap test", ["marker": marker])
            await WinstonLog.flush()

            let contents = try dailyLogContents(under: base.url)
            try #require(contents.contains("label=test.bootstrap"))
            try #require(contents.contains("marker=\(marker)"))
        }
    }

    @Test
    func flushBlockingReturnsOnceTheRecordIsInTheFile() async {
        await #expect(processExitsWith: .success) {
            let base = try TemporaryFolder()
            defer { base.remove() }
            WinstonLog.bootstrap(baseOverride: base.url)
            let marker = UUID().uuidString
            Logger(label: "test.flushBlocking").notice("flushBlocking test", ["marker": marker])

            // A generous timeout, so a loaded machine can't make it return before the write.
            WinstonLog.flushBlocking(timeout: .seconds(30))

            let contents = try dailyLogContents(under: base.url)
            try #require(contents.contains("marker=\(marker)"))
        }
    }

    /// A base that is a regular file makes `LogDirectory` throw, so the bootstrap fails. The OSLog
    /// breadcrumb isn't checked: under `swift test`, `OSLogStore(scope: .currentProcessIdentifier)`
    /// returned no entries at all, not even one the test logged itself with `os.Logger`.
    @Test
    func aFailedBootstrapCarriesOnWithoutALogFile() async {
        await #expect(processExitsWith: .success) {
            let base = try TemporaryFolder()
            defer { base.remove() }
            let notAFolder = base.url.appending(path: "not-a-folder")
            try Data("x".utf8).write(to: notAFolder)

            WinstonLog.bootstrap(baseOverride: notAFolder)

            // No handle: both flushes return, and flushBlocking doesn't wait out its timeout.
            await WinstonLog.flush()
            let elapsed = ContinuousClock().measure {
                WinstonLog.flushBlocking(timeout: .seconds(30))
            }
            #expect(elapsed < .seconds(5))

            // Nothing was made: no Logs/Winston, and the base is still a regular file.
            let made = try FileManager.default.contentsOfDirectory(atPath: base.url.path(percentEncoded: false))
            #expect(made == ["not-a-folder"])
            var isDirectory: ObjCBool = true
            #expect(FileManager.default.fileExists(atPath: notAFolder.path(percentEncoded: false), isDirectory: &isDirectory))
            #expect(!isDirectory.boolValue)
        }
    }
}

/// The contents of the one `app-yyyy-MM-dd.log` file in `<base>/Logs/Winston`.
private func dailyLogContents(under base: URL) throws -> String {
    let logs = base.appending(path: "Logs/Winston", directoryHint: .isDirectory)
    let daily = try FileManager.default.contentsOfDirectory(atPath: logs.path(percentEncoded: false))
        .filter { $0.wholeMatch(of: /app-\d{4}-\d{2}-\d{2}\.log/) != nil }
    let file = try #require(daily.first, "no app-yyyy-MM-dd.log in Logs/Winston")
    return try String(contentsOf: logs.appending(path: file), encoding: .utf8)
}
#endif
