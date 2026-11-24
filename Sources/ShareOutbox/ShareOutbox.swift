import Foundation
import Logging
import LogSupport

/// The hand-off from Winston's iOS share extension to the app, in the App Group container they
/// share. The extension can't run TDLib, so it saves what the share sheet hands it and opens
/// Winston with `openURL`. Winston opens each file the next time it's active, as it opens a file
/// from Open in: its Send to Agent sheet asks which agent it goes to (`AppModel.openSharedFiles()`).
///
/// The extension copies the files it is handed into a batch folder in `Staging` as soon as it
/// opens (`stage(_:)`), each in a folder of its own under its own name. Once they're all copied,
/// it moves the whole batch into `Outbox` in one rename (`publish(_:)`), so Winston never sees a
/// file half copied, nor a share Adam cancelled; Cancel removes it (`discard(_:)`). What an
/// interrupted or cancelled save leaves in `Staging` goes later (`removeLeftovers(before:)`).
///
/// The logs give counts only, never file names or contents.
public struct ShareOutbox: Sendable {
    /// The App Group the app and the extension share. Both entitlements files name it.
    public static let appGroupIdentifier = "group.com.milestonemade.winston"

    /// The URL scheme Winston registers in `App/Config/Info.plist`. Its bundle ID, so no other
    /// app claims it.
    public static let urlScheme = "com.milestonemade.winston"

    /// What the extension opens Winston with, once it has saved the files.
    /// `AppModel.open(_:)` scans the outbox when it's handed this.
    public static let openURL = URL(string: "\(urlScheme)://share")

    /// Whether `url` is in Winston's scheme, as `openURL` is.
    public static func isWinstonURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == urlScheme
    }

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

    /// The shared files waiting for Winston, in the order they were shared, found off the caller's
    /// actor. Each is alone in its folder, which Winston removes once it has its own copy, or on
    /// Cancel. A batch whose files have all gone is removed here.
    @concurrent
    public func files() async -> [URL] {
        let batches = (contents(of: outboxFolder, keys: [.creationDateKey], skippingHidden: true) ?? [])
            .map { batch in (batch, (try? batch.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        var files: [URL] = []
        for listed in batches {
            // Under `outboxFolder` as given: the listing resolves /var to /private/var.
            let batch = outboxFolder.appending(path: listed.lastPathComponent, directoryHint: .isDirectory)
            // A batch that can't be read now is left for the next look.
            guard let listedItems = contents(of: batch, keys: [], skippingHidden: true) else { continue }
            // Named by their place in the batch.
            let items = listedItems.map(\.lastPathComponent).sorted()
            guard !items.isEmpty else {
                // Only an empty folder: rmdir turns down one with anything in it.
                if rmdir(batch.path(percentEncoded: false)) != 0 {
                    Self.log.warning("removing an emptied share batch failed", ["errno": errno])
                }
                continue
            }
            for item in items {
                let folder = batch.appending(path: item, directoryHint: .isDirectory)
                // The one file in it, hidden or not, as a name such as ".env" is. An empty item
                // folder, which nothing leaves, is skipped.
                guard let name = contents(of: folder, keys: [], skippingHidden: false)?.first?.lastPathComponent else { continue }
                files.append(folder.appending(path: name))
            }
        }
        return files
    }

    /// Removes what saves left in `Staging` from before `cutoff`, as when iOS ended the extension
    /// mid-copy, or after Cancel. Returns how many it removed, which it logs. A share still being
    /// copied is in `Staging` too, as while an iCloud Drive file downloads, so the cutoff is well
    /// before any copy would still be under way.
    @concurrent
    @discardableResult
    public func removeLeftovers(before cutoff: Date) async -> Int {
        var removed = 0
        for batch in contents(of: stagingFolder, keys: [.creationDateKey], skippingHidden: true) ?? [] {
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

    /// What's in `folder`: none if it doesn't exist yet, and nil if it can't be read, which the
    /// caller must not take for empty.
    func contents(of folder: URL, keys: [URLResourceKey], skippingHidden: Bool) -> [URL]? {
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
            return nil
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
