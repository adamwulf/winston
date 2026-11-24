import Foundation
import VoiceLoop

/// A pronunciation as it is saved and synced between Adam's devices: with when it was last
/// written, or as a tombstone once it is removed, so the removal syncs too. Saved flat, the
/// pronunciation's fields beside `updatedAt` and `deleted`.
package struct PronunciationRecord: Codable, Hashable, Sendable {
    /// For a tombstone only its id counts: the word and replacement are blank.
    package var pronunciation: Pronunciation
    /// When it was last written, on the clock of the device that wrote it.
    package var updatedAt: Date
    /// Whether it is a tombstone: a pronunciation that was removed.
    package var deleted: Bool

    package var id: UUID { pronunciation.id }

    /// A live record of `pronunciation`.
    package init(_ pronunciation: Pronunciation, updatedAt: Date) {
        self.pronunciation = pronunciation
        self.updatedAt = updatedAt
        deleted = false
    }

    /// The tombstone of the pronunciation with `id`, removed at `updatedAt`.
    package static func tombstone(id: UUID, updatedAt: Date) -> PronunciationRecord {
        var record = PronunciationRecord(Pronunciation(id: id), updatedAt: updatedAt)
        record.deleted = true
        return record
    }

    /// The records in `data`, as `encoded(_:)` saves them. One saved before sync, with no
    /// `updatedAt`, takes `unstampedAt` (the device's first launch with sync), and is live.
    package static func decoded(from data: Data, unstampedAt: Date) throws -> [PronunciationRecord] {
        let decoder = JSONDecoder()
        decoder.userInfo[unstampedUpdatedAt] = unstampedAt
        return try decoder.decode([PronunciationRecord].self, from: data)
    }

    package static func encoded(_ records: [PronunciationRecord]) throws -> Data {
        try JSONEncoder().encode(records)
    }

    /// Where `decoded(from:unstampedAt:)` puts its `unstampedAt` for `init(from:)`.
    private static let unstampedUpdatedAt = CodingUserInfoKey(rawValue: "unstampedUpdatedAt")!

    private enum CodingKeys: String, CodingKey {
        case updatedAt, deleted
    }

    package init(from decoder: any Decoder) throws {
        pronunciation = try Pronunciation(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? decoder.userInfo[Self.unstampedUpdatedAt] as? Date else {
            throw DecodingError.keyNotFound(
                CodingKeys.updatedAt,
                .init(codingPath: decoder.codingPath, debugDescription: "no updatedAt, and no first launch to stand for it")
            )
        }
        self.updatedAt = updatedAt
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }

    package func encode(to encoder: any Encoder) throws {
        try pronunciation.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(deleted, forKey: .deleted)
    }
}

/// How two devices' pronunciation records become one list: for each id, the record written
/// last wins, tombstones included. Pure, so both devices reach the same records.
package enum PronunciationSync {
    /// How long a tombstone is kept, 90 days. A device that doesn't open Winston for longer can
    /// bring its pronunciation back.
    package static let tombstoneLifetime: TimeInterval = 90 * 24 * 60 * 60
    /// The most iCloud's key-value store holds, 1 MB. A larger write fails as a whole.
    package static let storeLimit = 1_000_000

    /// `local` and `remote` as one list: for each id, the `newer(_:_:)` of the two. In
    /// `local`'s order, then the ids only `remote` has, in its order.
    package static func merged(_ local: [PronunciationRecord], _ remote: [PronunciationRecord]) -> [PronunciationRecord] {
        var remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: newer)
        var merged = local.map { record in
            remoteByID.removeValue(forKey: record.id).map { newer(record, $0) } ?? record
        }
        for record in remote {
            if let remoteOnly = remoteByID.removeValue(forKey: record.id) {
                merged.append(remoteOnly)
            }
        }
        return merged
    }

    /// The one of two records of an id that wins: the one written later. Of two written at the
    /// same time a tombstone wins, then the one greater by word, replacement, mode and whether it
    /// matches case, so either device picks the same one.
    package static func newer(_ first: PronunciationRecord, _ second: PronunciationRecord) -> PronunciationRecord {
        if first.updatedAt != second.updatedAt {
            return first.updatedAt > second.updatedAt ? first : second
        }
        if first.deleted != second.deleted {
            return first.deleted ? first : second
        }
        let (a, b) = (first.pronunciation, second.pronunciation)
        return (a.word, a.replacement, a.mode.rawValue, a.matchesCase ? 1 : 0)
            >= (b.word, b.replacement, b.mode.rawValue, b.matchesCase ? 1 : 0) ? first : second
    }

    /// `records` with one live pronunciation per word, for the first merge with another
    /// device's list: two lists made before sync have different ids for the same word. The one
    /// written last stays (of two written at the same time, the greater id); the others become
    /// tombstones, stamped `now` unless they were written later. A blank word is left alone:
    /// it is still being typed.
    package static func deduplicatedByWord(_ records: [PronunciationRecord], now: Date) -> [PronunciationRecord] {
        func word(_ record: PronunciationRecord) -> String? {
            let word = record.pronunciation.word.trimmingCharacters(in: .whitespacesAndNewlines)
            return record.deleted || word.isEmpty ? nil : word
        }
        var keptByWord: [String: PronunciationRecord] = [:]
        for record in records {
            guard let word = word(record) else { continue }
            if let kept = keptByWord[word],
               (kept.updatedAt, kept.id.uuidString) >= (record.updatedAt, record.id.uuidString) {
                continue
            }
            keptByWord[word] = record
        }
        let keptIDs = Set(keptByWord.values.map(\.id))
        return records.map { record in
            guard word(record) != nil, !keptIDs.contains(record.id) else { return record }
            return .tombstone(id: record.id, updatedAt: max(now, record.updatedAt))
        }
    }

    /// `records` without the tombstones older than `tombstoneLifetime`.
    package static func pruned(_ records: [PronunciationRecord], now: Date) -> [PronunciationRecord] {
        records.filter { !$0.deleted || now.timeIntervalSince($0.updatedAt) < tombstoneLifetime }
    }
}

/// Where the pronunciation records sync between Adam's devices: iCloud's key-value store in the
/// app (`ICloudPronunciationStore`), and a fake in tests.
@MainActor
package protocol PronunciationSyncStore: AnyObject {
    /// The records as last saved here or synced from another device, or nil if there are none.
    var data: Data? { get }
    /// Saves `data` here, to sync to the other devices.
    func save(_ data: Data)
    /// Asks for what the other devices saved since this one last looked. The model calls it each
    /// time the app comes back to the foreground; `ICloudPronunciationStore` also calls it as it
    /// is made, at launch.
    func refresh()
    /// Calls `handler` each time another device's records arrive, once `data` has them.
    func onExternalChange(_ handler: @escaping @MainActor @Sendable () -> Void)
}
