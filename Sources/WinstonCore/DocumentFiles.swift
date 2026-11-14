import Foundation

/// File work for sending a picked file as a document, done off the main actor.
public enum DocumentFiles {
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
        do {
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return copy
    }
}
