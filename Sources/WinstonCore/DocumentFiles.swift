import Foundation
import Logging
import LogSupport

/// File work for sending a picked file as a document, done off the main actor.
public enum DocumentFiles {
    private static let log = Logger(label: "app.documents")

    /// Copies a picked file into a new folder in the temporary directory, under its own name, which
    /// Telegram shows as the document's name, and returns the copy to pass to `sendDocument`.
    ///
    /// The file picker hands over a security-scoped URL whose access ends long before TDLib's
    /// upload does, so the copy is made while access lasts and TDLib reads the copy.
    @concurrent
    public static func copyForSending(from url: URL) async throws -> URL {
        // False for a URL that isn't security scoped, which is still readable if it's the app's own.
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { url.stopAccessingSecurityScopedResource() }
        }
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: url.lastPathComponent)
        // A coordinated read, so a file provider such as iCloud Drive can download the file first.
        var coordinationError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            do {
                try FileManager.default.copyItem(at: readableURL, to: copy)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError {
            removeFolder(folder)
            throw error
        }
        return copy
    }

    /// Removes a copy from `copyForSending`, and its folder, when nothing will upload it. A failure is
    /// only logged: the system empties the temporary directory in time anyway.
    public static func removeCopy(_ copy: URL) {
        removeFolder(copy.deletingLastPathComponent())
    }

    private static func removeFolder(_ folder: URL) {
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            // Codes only: a file error's description names the file.
            log.warning("removing a document copy failed", error.logCodes())
        }
    }
}
