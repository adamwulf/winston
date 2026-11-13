import Foundation

/// Where Winston's log files live: `<Library>/Logs/Winston/`.
///
/// On macOS the app is sandboxed, so `<Library>` is the one inside its container; on iOS
/// `Library` isn't purged like `Caches`. The `Winston` folder keeps the logs apart from anything
/// else in `Logs/`, because FellerBuncher prunes every old `.log` file in its directory. That
/// matters when an unsigned (so unsandboxed) Mac build would otherwise write to `~/Library/Logs/`.
public enum LogDirectory {

    public enum Failure: Error, LocalizedError {
        case libraryDirectoryUnavailable

        public var errorDescription: String? {
            switch self {
            case .libraryDirectoryUnavailable:
                return "The Library folder isn't available."
            }
        }
    }

    /// `<Library>/Logs/Winston/`, created if missing.
    ///
    /// - Parameter baseOverride: tests pass a temporary folder here in place of `<Library>`, so
    ///   they never touch the real one.
    public static func logsDirectoryURL(baseOverride: URL? = nil) throws -> URL {
        let base: URL
        if let baseOverride {
            base = baseOverride
        } else if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            base = library
        } else {
            throw Failure.libraryDirectoryUnavailable
        }
        let logs = base
            .appending(path: "Logs", directoryHint: .isDirectory)
            .appending(path: "Winston", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs
    }
}
