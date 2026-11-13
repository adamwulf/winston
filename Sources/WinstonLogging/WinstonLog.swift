import FellerBuncher
import Foundation
import LogSupport
// Only for `bootstrapFailureLog`, the one exception to the no-os.Logger rule.
import os
import Synchronization

/// Public entry point for file logging. Bootstraps swift-log once per process onto
/// FellerBuncher: a daily logfmt file in `LogDirectory`, plus an OSLog console echo.
///
/// Every `Logger(label:)` in the app and the libraries routes to the same file,
/// `<Library>/Logs/Winston/app-yyyy-MM-dd.log` (date in UTC). FellerBuncher rolls it at the day
/// boundary and prunes files older than its 7-day retention.
///
/// Never call `LoggingSystem.bootstrap` anywhere else: FellerBuncher makes the one call, and a
/// second one crashes.
public enum WinstonLog {

    /// The log file's name prefix: `app-yyyy-MM-dd.log`.
    public static let processName = "app"

    /// Where the bootstrap-failure breadcrumb goes: the single exception to the rule that
    /// everything logs through swift-log.
    ///
    /// When FellerBuncher's `bootstrap` throws, it throws before it activates the pre-config
    /// capture installed below, so the capture stays in buffering mode for the rest of the run.
    /// Every swift-log record after that, including one about the failure, lands in its bounded
    /// in-memory ring (the newest `defaultPreConfigBufferCapacity` records, 1,000, oldest dropped)
    /// and is never written to the file or to Console. FellerBuncher has no console-only
    /// bootstrap to fall back to, so this one record goes straight to OSLog, where Console.app
    /// and the Xcode console show it.
    private static let bootstrapFailureLog = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Winston",
        category: "logging.bootstrap"
    )

    /// The handle FellerBuncher's bootstrap returned, for `flush()`. Nil before bootstrap,
    /// or when it failed.
    private static let handle = Mutex<LoggingHandle?>(nil)

    /// Bootstraps swift-log onto FellerBuncher. Call it first thing at launch, before anything
    /// creates a `Logger`. Idempotent: later calls do nothing. Logging is never fatal: a failure
    /// is reported to OSLog (see `bootstrapFailureLog`) and the app carries on without a log file.
    ///
    /// - Parameter baseOverride: tests pass a temporary folder in place of `<Library>`.
    public static func bootstrap(processName: String = WinstonLog.processName, baseOverride: URL? = nil) {
        // Install the pre-config capturing handler FIRST, so a `Logger(label:)` created before
        // this bootstrap completes isn't lost: FellerBuncher buffers its records and replays
        // them into the file (tagged `late=true`) once the real destinations come up. If the
        // bootstrap below fails, they never come up; see `bootstrapFailureLog`. This is the
        // single `LoggingSystem.bootstrap` call; FellerBuncher's `bootstrap` below activates the
        // same coordinator rather than bootstrapping again.
        installPreConfigCapture()

        do {
            let logsDir = try LogDirectory.logsDirectoryURL(baseOverride: baseOverride)
            // `.dateStamped()` writes `<process>-yyyy-MM-dd.log` (UTC date) and rolls at the day
            // boundary. Everything else is FellerBuncher's default: OSLog console echo,
            // `.info` minimum level, logfmt format, 7-day retention.
            let logging = try FellerBuncher.bootstrap(
                processName: processName,
                logDir: logsDir,
                rotationPolicy: .dateStamped()
            )
            handle.withLock { $0 = logging }
        } catch {
            // Codes only: a file error's description can name the folder's path.
            let codes = error.logCodes()
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            bootstrapFailureLog.fault("logging bootstrap failed \(codes, privacy: .public)")
        }
    }

    /// Returns once every record logged so far has reached the log file. FellerBuncher writes
    /// on its own queue, so call this before reading or zipping the files.
    public static func flush() async {
        let logging = handle.withLock { $0 }
        await logging?.drain()
    }

    /// `flush()` for a caller that can't await, such as `applicationWillTerminate` right before
    /// `_exit`. Blocks for at most `timeout`, so a stuck writer can't hold up termination.
    /// FellerBuncher's own blocking `drain()` has no timeout and is meant for tests, so this
    /// waits on its callback form instead. Its destinations drain on their own queues, never the
    /// main thread, so blocking the main thread here can't deadlock them.
    public static func flushBlocking(timeout: DispatchTimeInterval = .seconds(1)) {
        guard let logging = handle.withLock({ $0 }) else { return }
        let flushed = DispatchSemaphore(value: 0)
        logging.drain {
            flushed.signal()
        }
        // A timeout can't be logged: the process is about to end, and the writer is stuck.
        _ = flushed.wait(timeout: .now() + timeout)
    }
}
