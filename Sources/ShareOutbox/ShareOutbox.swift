import Foundation
import Logging
import LogSupport

/// An agent the share extension can send a file to: one of Winston's bot chats, by its Telegram
/// chat ID and the name Winston shows for it.
public struct ShareAgent: Codable, Hashable, Identifiable, Sendable {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }
}

/// A file shared to an agent, waiting in the outbox for Winston to send it.
public struct OutboxItem: Equatable, Sendable {
    /// The Telegram chat ID of the agent it goes to.
    public let agentID: Int64
    /// The file's name, which Telegram shows as the document's name.
    public let fileName: String
    /// The file's uniform type identifier, such as "public.png" or "public.zip-archive".
    public let typeIdentifier: String
    public let createdAt: Date
    /// The folder holding the file, alone.
    public let folder: URL

    public var fileURL: URL {
        folder.appending(path: fileName)
    }

    /// The manifest file beside `folder`, named as it is.
    var manifestURL: URL {
        folder.deletingLastPathComponent().appending(path: folder.lastPathComponent + ".json")
    }
}

/// The hand-off between Winston and its iOS share extension, in the App Group container they
/// share. The extension can't run TDLib, so:
/// - Winston saves its agents (`saveAgents(_:)`) for the extension to list.
/// - The extension copies the shared file into the outbox with the agent picked (`add`).
/// - Winston sends what is in the outbox when it's opened, then removes it (`sendAll(_:)`).
///
/// In the outbox, each item is a folder named by a UUID, holding only the file, and a manifest
/// beside it, `<UUID>.json`: the agent, the file's name and type, and when it was shared. A
/// manifest can't share a name with a file this way. It's written once the file is copied, so
/// an item is only listed once it is whole.
///
/// The logs give counts and types only, never file names or contents.
public struct ShareOutbox: Sendable {
    /// The App Group the app and the extension share. Both entitlements files name it.
    public static let appGroupIdentifier = "group.com.milestonemade.winston"

    static let log = Logger(label: "share.outbox")

    /// The folder holding the agent list and the outbox.
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

    private var agentsFile: URL {
        folder.appending(path: "agents.json")
    }

    private var outboxFolder: URL {
        folder.appending(path: "Outbox", directoryHint: .isDirectory)
    }

    // MARK: - Agents

    /// Saves the agents for the share extension to list, in the order given.
    public func saveAgents(_ agents: [ShareAgent]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(agents).write(to: agentsFile, options: .atomic)
        Self.log.info("share agents saved", ["count": agents.count])
    }

    /// The agents Winston saved last, or none if it hasn't saved any.
    public func agents() throws -> [ShareAgent] {
        guard FileManager.default.fileExists(atPath: agentsFile.path(percentEncoded: false)) else { return [] }
        return try JSONDecoder().decode([ShareAgent].self, from: Data(contentsOf: agentsFile))
    }

    // MARK: - Outbox

    /// Copies the file at `url` into the outbox for the agent with `agentID`, named `fileName`, and
    /// returns the new item. A `/` in the name becomes `-`, since the name is one path component.
    @discardableResult
    public func add(
        fileAt url: URL,
        named fileName: String,
        typeIdentifier: String,
        for agentID: Int64,
        now: Date = Date()
    ) throws -> OutboxItem {
        let item = OutboxItem(
            agentID: agentID,
            fileName: Self.safeFileName(fileName),
            typeIdentifier: typeIdentifier,
            createdAt: now,
            folder: outboxFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        )
        do {
            try FileManager.default.createDirectory(at: item.folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: item.fileURL)
            // Last, so the item is listed only once its file is whole.
            try JSONEncoder().encode(Manifest(item)).write(to: item.manifestURL, options: .atomic)
        } catch {
            // Codes only: a file error's description names the file.
            Self.log.error("adding a shared file to the outbox failed", error.logCodes(["type": typeIdentifier]))
            removeFolder(of: item)
            throw error
        }
        Self.log.notice("shared file added to the outbox", ["type": typeIdentifier])
        return item
    }

    /// The items in the outbox, oldest first. An item whose manifest can't be read is left out
    /// and stays where it is.
    public func items() -> [OutboxItem] {
        guard FileManager.default.fileExists(atPath: outboxFolder.path(percentEncoded: false)) else { return [] }
        let manifests: [URL]
        do {
            manifests = try FileManager.default
                .contentsOfDirectory(at: outboxFolder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                .filter { $0.pathExtension == "json" }
        } catch {
            Self.log.error("reading the outbox failed", error.logCodes())
            return []
        }
        var items: [OutboxItem] = []
        for manifestURL in manifests {
            do {
                let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
                let name = manifestURL.deletingPathExtension().lastPathComponent
                items.append(manifest.item(in: outboxFolder.appending(path: name, directoryHint: .isDirectory)))
            } catch {
                Self.log.error("outbox manifest unreadable", error.logCodes())
            }
        }
        return items.sorted { $0.createdAt < $1.createdAt }
    }

    /// Removes `item`, its file and its manifest from the outbox.
    public func remove(_ item: OutboxItem) throws {
        try FileManager.default.removeItem(at: item.manifestURL)
        try FileManager.default.removeItem(at: item.folder)
    }

    /// Hands each item in the outbox to `send`, oldest first, and removes it once `send` returns,
    /// whether or not it was sent: `send` reports its own failure, and an item that failed once
    /// would fail the same way again. Returns how many items there were.
    @discardableResult
    public func sendAll(_ send: @Sendable (OutboxItem) async -> Void) async -> Int {
        let items = items()
        guard !items.isEmpty else { return 0 }
        Self.log.notice("sending the outbox", ["count": items.count])
        for item in items {
            await send(item)
            do {
                try remove(item)
                Self.log.info("outbox item removed", ["type": item.typeIdentifier])
            } catch {
                Self.log.error("removing an outbox item failed", error.logCodes(["type": item.typeIdentifier]))
            }
        }
        return items.count
    }

    /// A name that is one path component: no `/`, and not empty, `.` or `..`.
    static func safeFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "file" : cleaned
    }

    /// Removes what `add` made of an item it couldn't finish. A failure is only logged.
    private func removeFolder(of item: OutboxItem) {
        guard FileManager.default.fileExists(atPath: item.folder.path(percentEncoded: false)) else { return }
        do {
            try FileManager.default.removeItem(at: item.folder)
        } catch {
            Self.log.warning("removing an unfinished outbox item failed", error.logCodes())
        }
    }
}

/// What an item's manifest holds.
private struct Manifest: Codable {
    var agentID: Int64
    var fileName: String
    var typeIdentifier: String
    var createdAt: Date

    init(_ item: OutboxItem) {
        agentID = item.agentID
        fileName = item.fileName
        typeIdentifier = item.typeIdentifier
        createdAt = item.createdAt
    }

    func item(in folder: URL) -> OutboxItem {
        OutboxItem(agentID: agentID, fileName: fileName, typeIdentifier: typeIdentifier, createdAt: createdAt, folder: folder)
    }
}
