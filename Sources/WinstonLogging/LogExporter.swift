import Foundation

/// Zips the whole `Logs/Winston/` folder (every retained day's file) into one file for
/// "Export Debug Logs…".
///
/// Uses Foundation-only zipping via `NSFileCoordinator` with the `.forUploading` reading
/// intent, which produces a **zip** of the directory at a temporary URL.
public enum LogExporter {

    public enum ExportError: Error, LocalizedError {
        case zipNotProduced

        public var errorDescription: String? {
            switch self {
            case .zipNotProduced:
                return "Couldn't package the logs."
            }
        }
    }

    /// Flushes the log file, zips the Logs folder, and returns the zip: a temporary file named
    /// `Winston-Logs-yyyyMMdd-HHmmss.zip` (local time).
    ///
    /// - Parameters:
    ///   - timestamp: stamped into the file name.
    ///   - directoryOverride: tests inject the folder to zip directly.
    public static func exportLogs(timestamp: Date = Date(), directoryOverride: URL? = nil) async throws -> URL {
        await WinstonLog.flush()
        let logsDir = try directoryOverride ?? LogDirectory.logsDirectoryURL()
        let destination = FileManager.default.temporaryDirectory
            .appending(path: archiveName(for: timestamp), directoryHint: .notDirectory)
        return try await zip(logsDir, to: destination)
    }

    /// The zip's file name: `Winston-Logs-yyyyMMdd-HHmmss.zip`, in `timeZone`.
    static func archiveName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Winston-Logs-\(formatter.string(from: date)).zip"
    }

    /// File coordination blocks, so it runs off the caller's actor.
    @concurrent
    private static func zip(_ directory: URL, to destination: URL) async throws -> URL {
        let fileManager = FileManager.default
        // Remove a stale destination from an export in the same second, so copyItem succeeds.
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fileManager.removeItem(at: destination)
        }

        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var copyError: (any Error)?
        var produced: URL?

        coordinator.coordinate(
            readingItemAt: directory,
            options: [.forUploading],
            error: &coordinatorError
        ) { zippedURL in
            // Copy INSIDE the accessor block. Apple's docs: "The file coordinator unlinks the
            // file after the block returns, rendering it inaccessible through the URL."
            do {
                try fileManager.copyItem(at: zippedURL, to: destination)
                produced = destination
            } catch {
                copyError = error
            }
        }

        if let coordinatorError {
            throw coordinatorError
        }
        if let copyError {
            throw copyError
        }
        guard let produced else {
            throw ExportError.zipNotProduced
        }
        return produced
    }
}
