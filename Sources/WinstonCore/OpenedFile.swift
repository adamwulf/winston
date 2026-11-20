import Foundation
import Logging
import LogSupport

/// A file opened in Winston from another app, waiting in `AppModel.openedFiles` for Adam to pick
/// the agent it goes to: from the iOS share sheet, or with Open With or the Dock on the Mac.
public struct OpenedFile: Identifiable, Equatable, Sendable {
    public let id = UUID()
    /// Winston's own copy, in a folder of its own in the temporary directory, as
    /// `DocumentFiles.copyForSending` makes it.
    let copy: URL
    /// Whether it goes as a photo, as a still image (`PhotoFiles.isStillImage(at:)`) does.
    /// Anything else goes as a document.
    public let isPhoto: Bool

    /// The file's name, for the agent sheet. A document goes under it. Never logged.
    public var name: String {
        copy.lastPathComponent
    }

    /// How it goes, for the logs.
    var logKind: String {
        isPhoto ? "photo" : "document"
    }

    private static let log = Logger(label: "app.openedFiles")

    /// Copies the file at `url` for sending (see `DocumentFiles.copyForSending`, which turns down
    /// a folder), and finds out whether it is a still image. When `url` is in `inbox`, where iOS
    /// puts the copy it hands Winston, that copy is removed, whether or not Winston's own could be
    /// made: nothing else removes it.
    @concurrent
    static func receive(_ url: URL, removingFrom inbox: URL?) async throws -> OpenedFile {
        defer {
            if let inbox, isFile(url, in: inbox) {
                removeSystemCopy(url)
            }
        }
        let copy = try await DocumentFiles.copyForSending(from: url)
        return OpenedFile(copy: copy, isPhoto: await PhotoFiles.isStillImage(at: copy))
    }

    /// Whether `url` is inside `folder`. Symbolic links are resolved first: iOS may hand over a
    /// path under /private/var for a folder Foundation names under /var.
    private static func isFile(_ url: URL, in folder: URL) -> Bool {
        let file = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return file.count > folder.count && file.starts(with: folder)
    }

    private static func removeSystemCopy(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // Codes only: a file error's description names the file.
            log.warning("removing the system's copy of an opened file failed", error.logCodes())
        }
    }
}
