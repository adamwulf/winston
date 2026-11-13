import Foundation
import Testing
import WinstonLogging

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

            let logs = base.url.appending(path: "Logs/Winston", directoryHint: .isDirectory)
            let daily = try FileManager.default.contentsOfDirectory(atPath: logs.path(percentEncoded: false))
                .filter { $0.wholeMatch(of: /app-\d{4}-\d{2}-\d{2}\.log/) != nil }
            let file = try #require(daily.first, "no app-yyyy-MM-dd.log in Logs/Winston")
            let contents = try String(contentsOf: logs.appending(path: file), encoding: .utf8)
            try #require(contents.contains("label=test.bootstrap"))
            try #require(contents.contains("marker=\(marker)"))
        }
    }
}
