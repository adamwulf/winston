import Foundation
import Testing
import VoiceLoop
import WinstonCore

/// A moment to stamp records with, and the ones after it.
private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func live(_ id: UUID, _ word: String, _ replacement: String, at seconds: TimeInterval) -> PronunciationRecord {
    PronunciationRecord(Pronunciation(id: id, word: word, replacement: replacement), updatedAt: start + seconds)
}

private func tombstone(_ id: UUID, at seconds: TimeInterval) -> PronunciationRecord {
    .tombstone(id: id, updatedAt: start + seconds)
}

/// Two devices' records merged: for each pronunciation, the record written last wins.
struct PronunciationMergeTests {
    @Test func theRecordWrittenLaterWinsWhicheverSideHasIt() {
        let id = UUID()
        let older = live(id, "JSON", "Jason", at: 0)
        let newer = live(id, "JSON", "Jay-son", at: 10)

        #expect(PronunciationSync.merged([older], [newer]) == [newer])
        #expect(PronunciationSync.merged([newer], [older]) == [newer])
    }

    @Test func aLaterRemovalWinsOverAnEarlierEditAndALaterEditOverAnEarlierRemoval() {
        let id = UUID()
        let edit = live(id, "JSON", "Jason", at: 0)
        let removal = tombstone(id, at: 10)
        let editAgain = live(id, "JSON", "Jay-son", at: 20)

        #expect(PronunciationSync.merged([edit], [removal]) == [removal])
        #expect(PronunciationSync.merged([removal], [edit]) == [removal])
        #expect(PronunciationSync.merged([removal], [editAgain]) == [editAgain])
        #expect(PronunciationSync.merged([editAgain], [removal]) == [editAgain])
    }

    @Test func recordsWrittenAtTheSameTimeMergeTheSameWayOnBothDevices() {
        let id = UUID()
        let edit = live(id, "JSON", "Jason", at: 0)
        let removal = tombstone(id, at: 0)
        let otherEdit = live(id, "JSON", "Jay-son", at: 0)

        // A removal wins a tie.
        #expect(PronunciationSync.merged([edit], [removal]) == [removal])
        #expect(PronunciationSync.merged([removal], [edit]) == [removal])
        // Of two edits, the same one on either device.
        #expect(PronunciationSync.merged([edit], [otherEdit]) == PronunciationSync.merged([otherEdit], [edit]))
        // Of two that differ only in whether they match case, the one that doesn't: a build from
        // before the choice saves the other, with the same stamp.
        var caseless = edit
        caseless.pronunciation.matchesCase = false
        #expect(PronunciationSync.merged([edit], [caseless]) == [caseless])
        #expect(PronunciationSync.merged([caseless], [edit]) == [caseless])
    }

    @Test func aLaterChangeOfWhetherItMatchesCaseWinsEitherWay() {
        let id = UUID()
        let on = live(id, "JSON", "Jason", at: 0)
        var off = live(id, "JSON", "Jason", at: 10)
        off.pronunciation.matchesCase = false
        let onAgain = live(id, "JSON", "Jason", at: 20)

        #expect(PronunciationSync.merged([on], [off]) == [off])
        #expect(PronunciationSync.merged([off], [on]) == [off])
        #expect(PronunciationSync.merged([off], [onAgain]) == [onAgain])
        #expect(PronunciationSync.merged([onAgain], [off]) == [onAgain])
    }

    @Test func mergingGivesTheSameRecordsEitherWayRoundAndAgainOnItsOwnResult() {
        let shared = UUID()
        let mac = [live(shared, "JSON", "Jason", at: 5), live(UUID(), "Kokoro", "Ko ko ro", at: 1), tombstone(UUID(), at: 2)]
        let iPhone = [live(shared, "JSON", "Jay-son", at: 7), live(UUID(), "API", "A P I", at: 3)]

        let onMac = PronunciationSync.merged(mac, iPhone)
        let onIPhone = PronunciationSync.merged(iPhone, mac)

        #expect(Set(onMac) == Set(onIPhone))
        #expect(onMac.count == 4)
        #expect(PronunciationSync.merged(onMac, onIPhone) == onMac)
        #expect(PronunciationSync.merged(onMac, onMac) == onMac)
    }

    @Test func theLocalOrderIsKeptAndTheOtherSidesNewOnesFollowInTheirOrder() {
        let (a, b, c, d) = (UUID(), UUID(), UUID(), UUID())
        let local = [live(b, "B", "bee", at: 0), live(a, "A", "ay", at: 0)]
        let remote = [live(d, "D", "dee", at: 0), live(a, "A", "ay", at: 9), live(c, "C", "see", at: 0)]

        let merged = PronunciationSync.merged(local, remote)

        #expect(merged.map(\.id) == [b, a, d, c])
        #expect(merged[1].updatedAt == start + 9)
    }
}

/// The first merge with another device's list: one pronunciation per word.
struct PronunciationDedupeTests {
    @Test func theEntryWrittenLastStaysAndTheOthersForItsWordBecomeTombstones() {
        let (old, new, other) = (UUID(), UUID(), UUID())
        let records = [
            live(old, "JSON", "Jason", at: 0),
            live(other, "Kokoro", "Ko ko ro", at: 0),
            live(new, " JSON ", "Jay-son", at: 5),
        ]

        let deduplicated = PronunciationSync.deduplicatedByWord(records, now: start + 100)

        #expect(deduplicated == [tombstone(old, at: 100), records[1], records[2]])
    }

    @Test func aTombstoneForAnEntryWrittenAfterNowTakesItsTime() {
        let (old, new) = (UUID(), UUID())
        let records = [live(old, "JSON", "Jason", at: 50), live(new, "JSON", "Jay-son", at: 60)]

        let deduplicated = PronunciationSync.deduplicatedByWord(records, now: start)

        #expect(deduplicated[0] == tombstone(old, at: 50))
        // So it wins over the entry it removes, on either device.
        #expect(PronunciationSync.merged([records[0]], [deduplicated[0]]) == [deduplicated[0]])
    }

    @Test func blankWordsAndTombstonesAreLeftAlone() {
        let records = [
            live(UUID(), "", "Jason", at: 0),
            live(UUID(), " ", "Jay-son", at: 1),
            tombstone(UUID(), at: 2),
            tombstone(UUID(), at: 3),
        ]

        #expect(PronunciationSync.deduplicatedByWord(records, now: start + 100) == records)
    }

    @Test func entriesWrittenAtTheSameTimeKeepTheGreaterIDOnBothDevices() {
        let ids = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let mac = [live(ids[0], "JSON", "Jason", at: 0), live(ids[1], "JSON", "Jay-son", at: 0)]

        let onMac = PronunciationSync.deduplicatedByWord(mac, now: start + 100)
        let onIPhone = PronunciationSync.deduplicatedByWord(mac.reversed(), now: start + 100)

        #expect(Set(onMac) == Set(onIPhone))
        #expect(onMac == [tombstone(ids[0], at: 100), mac[1]])
    }
}

/// Tombstones are kept for 90 days.
struct PronunciationPruningTests {
    @Test func tombstonesOlderThanNinetyDaysAreDroppedAndEverythingElseKept() {
        let day: TimeInterval = 24 * 60 * 60
        let records = [
            tombstone(UUID(), at: 0),
            tombstone(UUID(), at: day),
            live(UUID(), "JSON", "Jason", at: 0),
        ]

        let pruned = PronunciationSync.pruned(records, now: start + 90 * day)

        #expect(pruned == [records[1], records[2]])
    }
}

/// Records as the user defaults and the sync store hold them.
struct PronunciationRecordCodingTests {
    @Test func recordsComeBackAsTheyWereSaved() throws {
        let records = [
            PronunciationRecord(Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic), updatedAt: start + 0.25),
            PronunciationRecord(Pronunciation(word: "JSON", replacement: "Jason", matchesCase: false), updatedAt: start + 1),
            tombstone(UUID(), at: 3),
        ]

        let data = try PronunciationRecord.encoded(records)

        #expect(try PronunciationRecord.decoded(from: data, unstampedAt: .distantPast) == records)
        // Flat: whether it matches case sits beside the record's own fields.
        let objects = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(objects.map { $0["matchesCase"] as? Bool } == [true, false, true])
        #expect(objects.map { $0["deleted"] as? Bool } == [false, false, true])
    }

    @Test func pronunciationsSavedBeforeSyncAreLiveAndTakeTheFirstLaunchTime() throws {
        let id = UUID()
        let data = Data(#"[{"id": "\#(id.uuidString)", "word": "JSON", "replacement": "Jason", "mode": "respelling"}]"#.utf8)

        let records = try PronunciationRecord.decoded(from: data, unstampedAt: start)

        #expect(records == [live(id, "JSON", "Jason", at: 0)])
    }

    @Test func recordsSavedBeforeTheChoiceOfCaseMatchCase() throws {
        let id = UUID()
        // As JSONEncoder saves a date: seconds since the reference date.
        let data = Data(#"""
            [{"id": "\#(id.uuidString)", "word": "JSON", "replacement": "Jason", "mode": "respelling",
              "updatedAt": \#(start.timeIntervalSinceReferenceDate), "deleted": false}]
            """#.utf8)

        let records = try PronunciationRecord.decoded(from: data, unstampedAt: .distantPast)

        #expect(records == [live(id, "JSON", "Jason", at: 0)])
        #expect(records.map(\.pronunciation.matchesCase) == [true])
    }
}
