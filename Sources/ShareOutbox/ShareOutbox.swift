import Foundation
import Logging
import LogSupport

/// The hand-off from Winston's iOS share extension to the app, in the App Group container they
/// share. The extension can't run TDLib, nor open Winston, so it saves what the share sheet hands
/// it (`add(_:)`), and Winston opens each file the next time it's active, as it opens a file from
/// Open in: its Send to Agent sheet asks which agent it goes to (`AppModel.openSharedFiles()`).
///
/// Each file waits in a folder of its own in `Outbox`, under its own name. The extension copies
/// the files it is handed into a folder of their own in `Staging` first, and moves each into
/// `Outbox` once they all are, so Winston never sees a file half copied. What an interrupted save
/// leaves in `Staging` goes later (`removeLeftovers(before:)`).
///
/// The logs give counts only, never file names or contents.
public struct ShareOutbox: Sendable {
    /// The App Group the app and the extension share. Both entitlements files name it.
    public static let appGroupIdentifier = "group.com.milestonemade.winston"

    static let log = Logger(label: "share.outbox")

    /// The folder holding `Outbox` and `Staging`.
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// The share folder in the App Group container, or nil when the process isn't signed with the
    /// App Group, as in a build made without signing.
    public static func appGroup() -> ShareOutbox? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            log.error("app group container unavailable")
            return nil
        }
        return ShareOutbox(folder: container.appending(path: "Share", directoryHint: .isDirectory))
    }

    var outboxFolder: URL {
        folder.appending(path: "Outbox", directoryHint: .isDirectory)
    }

    var stagingFolder: URL {
        folder.appending(path: "Staging", directoryHint: .isDirectory)
    }

    /// The shared files waiting for Winston, in the order they were shared. Each is alone in its
    /// folder, which `remove(_:)` removes with it.
    public func files() -> [URL] {
        let folders = contents(of: outboxFolder, keys: [.creationDateKey], skippingHidden: true)
        let dated = folders.compactMap { listed -> (file: URL, date: Date)? in
            // The one file in it, hidden or not, as a name such as ".env" is. An empty folder,
            // which nothing leaves, is skipped.
            guard let name = contents(of: listed, keys: [], skippingHidden: false).first?.lastPathComponent else { return nil }
            let date = (try? listed.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            // Under `outboxFolder` as given: the listing resolves /var to /private/var.
            let folder = outboxFolder.appending(path: listed.lastPathComponent, directoryHint: .isDirectory)
            return (folder.appending(path: name), date)
        }
        return dated.sorted { $0.date < $1.date }.map(\.file)
    }

    /// Removes shared files and their folders: once Winston has its own copy, or when Adam
    /// cancels. A failure is only logged.
    public func remove(_ files: [URL]) {
        for file in files {
            Self.removeItem(at: file.deletingLastPathComponent())
        }
    }

    /// Removes what interrupted saves left in `Staging` from before `cutoff`, as when iOS ended
    /// the extension mid-copy. Returns how many it removed. A save under way is newer.
    @concurrent
    public func removeLeftovers(before cutoff: Date) async -> Int {
        var removed = 0
        for batch in contents(of: stagingFolder, keys: [.creationDateKey], skippingHidden: true) {
            guard let created = try? batch.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  created < cutoff else { continue }
            if Self.removeItem(at: batch) {
                removed += 1
            }
        }
        if removed > 0 {
            Self.log.notice("share staging leftovers removed", ["count": removed])
        }
        return removed
    }

    /// A name that is one path component: no `/`, and not empty, `.` or `..`.
    static func safeFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "file" : cleaned
    }

    /// What's in `folder`. None if it doesn't exist yet.
    func contents(of folder: URL, keys: [URLResourceKey], skippingHidden: Bool) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: keys,
                options: skippingHidden ? .skipsHiddenFiles : []
            )
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            // Codes only: a file error's description holds the container's path.
            Self.log.error("reading the share folder failed", error.logCodes())
            return []
        }
    }

    /// Removes `url`, logging a failure. Returns whether it's gone.
    @discardableResult
    static func removeItem(at url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            // Codes only: a file error's description names the file.
            log.warning("removing a shared file failed", error.logCodes())
            return false
        }
    }
}
