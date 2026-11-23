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
    /// Its place in the order the files were opened, kept when a failed upload brings it back.
    let sequence: Int
    /// The file as it was handed over, kept to copy it again after a failed copy.
    let source: URL
    /// The file iOS handed over, in one of Winston's inboxes: removed once this one is sent or
    /// cancelled. Nil for a file of Adam's own, as the Mac hands over, which stays.
    let systemCopy: URL?
    /// The folder the iOS share extension saved this file in, in the App Group (see
    /// `AppModel.openSharedFiles()`), which holds only it. It goes once Winston's copy is made, so
    /// the next activation doesn't open the file again, or on Cancel. Nil for a file opened any
    /// other way.
    var sharedFolder: URL?
    /// Winston's working copy, in a folder of its own in `AppModel.openedFileFolder`. Nil until
    /// it is made.
    var copy: URL?
    /// Why the copy couldn't be made, for the agent sheet, which offers to try again.
    public internal(set) var copyError: String?
    /// Whether it goes as a photo, as a still image (`PhotoFiles.isStillImage(at:)`) does.
    /// Anything else goes as a document. Known once it is copied.
    public internal(set) var isPhoto = false

    init(name: String, sequence: Int, source: URL, inboxes: [URL], sharedFolder: URL? = nil) {
        self.name = name
        self.sequence = sequence
        self.source = source
        systemCopy = inboxes.contains { Self.isFile(source, in: $0) } ? source : nil
        self.sharedFolder = sharedFolder
    }

    /// Whether Winston's copy is made, so it can be sent.
    public var isCopied: Bool {
        copy != nil
    }

    /// Whether Winston is still making its copy.
    public var isBeingCopied: Bool {
        copy == nil && copyError == nil
    }

    /// How it goes, for the logs.
    var logKind: String {
        isPhoto ? "photo" : "document"
    }

    private static let log = Logger(label: "app.openedFiles")

    /// What `copy(_:into:)` makes of a file.
    struct Copied: Sendable {
        let copy: URL
        let isPhoto: Bool
    }

    /// Copies the file at `url` into a folder of its own in `parent` (see
    /// `DocumentFiles.copyForSending`, which turns down a folder), and finds out whether it is a
    /// still image.
    @concurrent
    static func copy(_ url: URL, into parent: URL) async throws -> Copied {
        let copy = try await DocumentFiles.copyForSending(from: url, into: parent)
        return Copied(copy: copy, isPhoto: await PhotoFiles.isStillImage(at: copy))
    }

    /// Removes Winston's copy, the file iOS handed over, and the share extension's folder if it is
    /// still there, once the file is sent or won't be.
    func removeFiles() {
        copy.map(DocumentFiles.removeCopy)
        systemCopy.map(Self.remove)
        sharedFolder.map(Self.remove)
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

    /// Removes what opened files left in an earlier run, from before `cutoff`: Winston's working
    /// copies in `folder`, and the files iOS handed over in `inboxes`. Never a sent message's
    /// file: TDLib uploads a JPEG or a copy of its own, outside `folder`. Returns how many it
    /// removed. By when each arrived (the inode's change time), which a copy that keeps the
    /// original's dates still sets anew, so a file just handed over stays.
    @concurrent
    package static func removeLeftovers(in folder: URL, inboxes: [URL], before cutoff: Date) async -> Int {
        var removed = 0
        for directory in [folder] + inboxes {
            // None yet is nothing to remove.
            let items = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.attributeModificationDateKey]
            )) ?? []
            for item in items {
                guard let arrived = try? item.resourceValues(forKeys: [.attributeModificationDateKey]).attributeModificationDate,
                      arrived < cutoff else { continue }
                do {
                    try FileManager.default.removeItem(at: item)
                    removed += 1
                } catch {
                    // Codes only: a file error's description names the file.
                    log.warning("removing an opened file's leftover failed", error.logCodes())
                }
            }
        }
        return removed
    }

    /// Whether `url` is inside `folder`. Symbolic links are resolved first: iOS may hand over a
    /// path under /private/var for a folder Foundation names under /var. They are resolved in the
    /// file's folder, as Foundation only drops /private for a path that exists, and the file
    /// itself may not.
    private static func isFile(_ url: URL, in folder: URL) -> Bool {
        let file = url.standardizedFileURL
        let fileFolder = file.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return fileFolder.starts(with: folder)
    }
}
