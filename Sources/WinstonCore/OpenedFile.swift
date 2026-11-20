import Foundation
import Logging
import LogSupport

/// A file opened in Winston from another app, waiting in `AppModel.openedFiles` for Adam to pick
/// the agent it goes to: from the iOS share sheet, or with Open With or the Dock on the Mac. It
/// takes its place there as it is opened, before Winston's copy of it is made.
public struct OpenedFile: Identifiable, Equatable, Sendable {
    public let id = UUID()
    /// The file's name, for the agent sheet. A document goes under it. Never logged.
    public let name: String
    /// Winston's own copy, in a folder of its own in the temporary directory, as
    /// `DocumentFiles.copyForSending` makes it. Nil until it is made.
    var copy: URL?
    /// The file iOS handed over, in one of Winston's inboxes: removed once this one is sent or
    /// cancelled. Nil for a file of Adam's own, as the Mac hands over, which stays.
    var systemCopy: URL?
    /// Whether it goes as a photo, as a still image (`PhotoFiles.isStillImage(at:)`) does.
    /// Anything else goes as a document. Known once it is copied.
    public private(set) var isPhoto = false

    init(name: String) {
        self.name = name
    }

    /// Whether Winston's copy is made, so it can be sent.
    public var isCopied: Bool {
        copy != nil
    }

    /// How it goes, for the logs.
    var logKind: String {
        isPhoto ? "photo" : "document"
    }

    private static let log = Logger(label: "app.openedFiles")

    /// What `copy(_:inboxes:)` makes of a file.
    struct Copied: Sendable {
        let copy: URL
        let systemCopy: URL?
        let isPhoto: Bool
    }

    /// This file with its copy made.
    func with(_ copied: Copied) -> OpenedFile {
        var file = self
        file.copy = copied.copy
        file.systemCopy = copied.systemCopy
        file.isPhoto = copied.isPhoto
        return file
    }

    /// Copies the file at `url` for sending (see `DocumentFiles.copyForSending`, which turns down
    /// a folder), and finds out whether it is a still image. A file in one of `inboxes`, where iOS
    /// puts the copy it hands Winston, is the system's copy, to remove once the file is sent or
    /// cancelled. If no copy can be made it is removed now: nothing will send it.
    @concurrent
    static func copy(_ url: URL, inboxes: [URL]) async throws -> Copied {
        let systemCopy = inboxes.contains { isFile(url, in: $0) } ? url : nil
        do {
            let copy = try await DocumentFiles.copyForSending(from: url)
            return Copied(copy: copy, systemCopy: systemCopy, isPhoto: await PhotoFiles.isStillImage(at: copy))
        } catch {
            systemCopy.map(remove)
            throw error
        }
    }

    /// Removes Winston's copy and the system's, for a file that won't be sent.
    func removeFiles() {
        copy.map(DocumentFiles.removeCopy)
        systemCopy.map(Self.remove)
    }

    /// Removes a file Winston made or was handed. A failure is only logged.
    static func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // Codes only: a file error's description names the file.
            log.warning("removing an opened file's copy failed", error.logCodes())
        }
    }

    /// Whether `url` is inside `folder`. Symbolic links are resolved first: iOS may hand over a
    /// path under /private/var for a folder Foundation names under /var.
    private static func isFile(_ url: URL, in folder: URL) -> Bool {
        let file = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return file.count > folder.count && file.starts(with: folder)
    }
}
