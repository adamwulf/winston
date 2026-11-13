import Foundation
import Logging
import LogSupport

/// Zips the whole `Logs/Winston/` folder (every retained day's file) into one file for
/// "Export Debug Logs…".
///
/// Uses Foundation-only zipping via `NSFileCoordinator` with the `.forUploading` reading
/// intent, which produces a **zip** of the directory at a temporary URL.
public enum LogExporter {
    private static let log = Logger(label: "logging.export")

    public enum ExportError: Error, LocalizedError {
        case zipNotProduced

        public var errorDescription: String? {
            switch self {
            case .zipNotProduced:
                return "Couldn't package the logs."
            }
        }
    }

    /// Where exports go by default: a temporary folder of their own, emptied at the start of each
    /// export, so a zip left behind (say, a share sheet swiped away) doesn't pile up.
    public static var defaultOutputDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "DebugLogExports", directoryHint: .isDirectory)
    }

    /// Flushes the log file, zips the Logs folder, and returns the zip, named
    /// `Winston-Logs-yyyyMMdd-HHmmss.zip` (local time). Empties `outputDirectory` first, which
    /// removes earlier exports. Delete the zip once it's saved or shared.
    ///
    /// - Parameters:
    ///   - timestamp: stamped into the file name.
    ///   - directoryOverride: tests inject the folder to zip directly.
    ///   - outputDirectory: where the zip goes; tests pass their own folder.
    public static func exportLogs(
        timestamp: Date = Date(),
        directoryOverride: URL? = nil,
        outputDirectory: URL = LogExporter.defaultOutputDirectory
    ) async throws -> URL {
        await WinstonLog.flush()
        let logsDir = try directoryOverride ?? LogDirectory.logsDirectoryURL()
        return try await zip(logsDir, into: outputDirectory, named: archiveName(for: timestamp))
    }

    /// Copies an exported zip to `destination`, the place the user chose in a save panel. A
    /// file already there is replaced: the panel has asked whether to.
    public static func save(_ archive: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: archive, to: destination)
    }

    /// Removes an exported zip once it has been saved or shared. A failure is only logged: the
    /// next export empties the folder anyway.
    public static func remove(_ archive: URL) {
        do {
            try FileManager.default.removeItem(at: archive)
        } catch {
            // Codes only: a file error's description names the file.
            log.warning("removing the exported zip failed", error.logCodes())
        }
    }

    /// The zip's file name: `Winston-Logs-yyyyMMdd-HHmmss.zip`, in `timeZone`.
    static func archiveName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Winston-Logs-\(formatter.string(from: date)).zip"
    }

    /// Empties `outputDirectory`, then zips `directory` into it. File work and coordination
    /// block, so this runs off the caller's actor.
    @concurrent
    private static func zip(_ directory: URL, into outputDirectory: URL, named name: String) async throws -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputDirectory.path(percentEncoded: false)) {
            try fileManager.removeItem(at: outputDirectory)
        }
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let destination = outputDirectory.appending(path: name, directoryHint: .notDirectory)

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
