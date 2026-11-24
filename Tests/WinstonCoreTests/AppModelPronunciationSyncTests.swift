import Foundation
import Testing
import VoiceLoop
import VoiceLoopTestSupport
import WinstonCore

/// One of Adam's devices: user defaults of its own, its copy of the synced store, and the model
/// on them. No Telegram session: sync doesn't need one.
@MainActor
private final class Device {
    let store: FakePronunciationSyncStore
    private let testDefaults: TestDefaults
    private(set) var model: AppModel

    /// - Parameters:
    ///   - synced: what another device had saved to the store before this launch.
    ///   - saved: pronunciations this device saved before it had sync, as `[Pronunciation]`.
    init(synced: Data? = nil, saved: [Pronunciation]? = nil) throws {
        let testDefaults = TestDefaults()
        if let saved {
            testDefaults.defaults.set(try JSONEncoder().encode(saved), forKey: "pronunciations")
        }
        let store = FakePronunciationSyncStore(data: synced)
        self.testDefaults = testDefaults
        self.store = store
        model = Self.launch(defaults: testDefaults.defaults, store: store)
    }

    var defaults: UserDefaults {
        testDefaults.defaults
    }

    /// When this device first launched with sync, as it saved it.
    var firstLaunch: Date? {
        defaults.object(forKey: "pronunciationsFirstLaunch") as? Date
    }

    /// The records this device saved last, in its user defaults.
    func savedRecords() throws -> [PronunciationRecord] {
        try PronunciationRecord.decoded(from: #require(defaults.data(forKey: "pronunciations")), unstampedAt: .distantPast)
    }

    /// The records in this device's copy of the store.
    func syncedRecords() throws -> [PronunciationRecord] {
        try PronunciationRecord.decoded(from: #require(store.data), unstampedAt: .distantPast)
    }

    /// The app launched again on this device: a new model on the same defaults and store.
    func relaunch() {
        model = Self.launch(defaults: defaults, store: store)
    }

    private static func launch(defaults: UserDefaults, store: FakePronunciationSyncStore) -> AppModel {
        AppModel(
            link: nil,
            voiceLoop: VoiceTestBed().makeLoop(),
            defaults: defaults,
            pronunciationSuggester: FakePronunciationSuggester(),
            pronunciationSyncStore: store
        )
    }
}

/// The pronunciations sync between Adam's devices through iCloud's key-value store: for each
/// pronunciation, the record written last wins, and a removal leaves a tombstone.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PronunciationSyncModelTests {
    @Test func anEditStampsOnlyThePronunciationThatChangedAndSyncsIt() throws {
        // Written a minute ago, so a new stamp is later.
        let minuteAgo = Date() - 60
        let before = [
            PronunciationRecord(Pronunciation(word: "JSON", replacement: "Jason"), updatedAt: minuteAgo),
            PronunciationRecord(Pronunciation(word: "Kokoro", replacement: "Ko ko ro"), updatedAt: minuteAgo),
        ]
        let device = try Device(synced: try PronunciationRecord.encoded(before))
        let model = device.model

        model.pronunciations[1].replacement = "Koh koh roh"

        let after = try device.syncedRecords()
        #expect(after.map(\.pronunciation) == model.pronunciations)
        #expect(after[0] == before[0])
        #expect(after[1].updatedAt > minuteAgo + 30)
        #expect(try device.savedRecords() == after)
        #expect(device.store.saves.count == 1)
    }

    @Test func aRemovalSyncsATombstoneWithNothingButItsID() throws {
        let device = try Device()
        let model = device.model
        model.pronunciations = [
            Pronunciation(word: "JSON", replacement: "Jason"),
            Pronunciation(word: "Kokoro", replacement: "Ko ko ro"),
        ]
        let removed = model.pronunciations[0]

        model.pronunciations.remove(at: 0)

        let synced = try device.syncedRecords()
        #expect(synced.map(\.pronunciation) == [model.pronunciations[0], Pronunciation(id: removed.id)])
        #expect(synced.map(\.deleted) == [false, true])
        #expect(model.voiceLoop.pronunciations == model.pronunciations)
    }

    @Test func pronunciationsSavedBeforeSyncAreStampedWithTheFirstLaunchAndSynced() throws {
        let saved = [Pronunciation(word: "JSON", replacement: "Jason")]

        let device = try Device(saved: saved)

        let firstLaunch = try #require(device.firstLaunch)
        #expect(device.model.pronunciations == saved)
        #expect(try device.syncedRecords() == [PronunciationRecord(saved[0], updatedAt: firstLaunch)])

        // A relaunch keeps the time of the first.
        device.relaunch()

        #expect(device.firstLaunch == firstLaunch)
        #expect(device.model.pronunciations == saved)
        #expect(device.store.saves.count == 1)
    }

    @Test func atLaunchNewerSyncedRecordsReplaceLocalOnesAndOnlyWhatIsNewHereIsWrittenBack() throws {
        let saved = Pronunciation(word: "JSON", replacement: "Jason")
        var edited = saved
        edited.replacement = "Jay-son"
        // Another device edited it, and the store has nothing this one doesn't.
        let newer = PronunciationRecord(edited, updatedAt: Date() + 60)

        let device = try Device(synced: try PronunciationRecord.encoded([newer]), saved: [saved])

        #expect(device.model.pronunciations == [edited])
        #expect(device.model.voiceLoop.pronunciations == [edited])
        #expect(try device.savedRecords() == [newer])
        #expect(device.store.saves.isEmpty)

        // One added here while the store didn't have it is written back.
        let added = Pronunciation(word: "Kokoro", replacement: "Ko ko ro")
        device.model.pronunciations.append(added)
        device.store.receive(try PronunciationRecord.encoded([newer]))

        #expect(device.model.pronunciations == [edited, added])
        #expect(try device.syncedRecords().map(\.pronunciation) == [edited, added])
    }

    @Test func anotherDevicesWriteIsAppliedAsWrittenAndNotWrittenBack() throws {
        let device = try Device()
        let model = device.model
        model.pronunciations = [Pronunciation(word: "JSON", replacement: "Jason")]
        var edited = model.pronunciations[0]
        edited.replacement = "Jay-son"
        let theirs = [
            PronunciationRecord(edited, updatedAt: Date() + 60),
            PronunciationRecord(Pronunciation(word: "API", replacement: "A P I"), updatedAt: Date() + 60),
        ]
        let saves = device.store.saves.count

        device.store.receive(try PronunciationRecord.encoded(theirs))

        #expect(model.pronunciations == theirs.map(\.pronunciation))
        #expect(model.voiceLoop.pronunciations == theirs.map(\.pronunciation))
        // Not restamped as if edited here.
        #expect(try device.savedRecords() == theirs)
        #expect(device.store.saves.count == saves)
    }

    @Test func onlyAMergeThatBringsInAnotherDevicesPronunciationsDedupesByWord() throws {
        // Two for the same word on this device.
        let device = try Device(saved: [
            Pronunciation(word: "JSON", replacement: "Jason"),
            Pronunciation(word: "JSON", replacement: "Jay-son"),
        ])

        // A store holding only this device's own records, as before the entitlement, dedupes
        // nothing.
        device.relaunch()

        #expect(device.model.pronunciations.count == 2)
        #expect(!device.defaults.bool(forKey: "pronunciationsMergedFromICloud"))

        // Another device's pronunciation arriving does.
        let theirs = PronunciationRecord(Pronunciation(word: "API", replacement: "A P I"), updatedAt: Date())
        device.store.receive(try PronunciationRecord.encoded(try device.syncedRecords() + [theirs]))

        #expect(device.model.pronunciations.map(\.word) == ["JSON", "API"])
        #expect(device.defaults.bool(forKey: "pronunciationsMergedFromICloud"))

        // And only that once: the same word added again on another device stays.
        let again = PronunciationRecord(Pronunciation(word: "API", replacement: "Ay pee eye"), updatedAt: Date() + 60)
        device.store.receive(try PronunciationRecord.encoded(try device.syncedRecords() + [again]))

        #expect(device.model.pronunciations.map(\.word) == ["JSON", "API", "API"])
    }

    @Test func anUnreadableSyncedValueIsLeftOutOfTheMergeAndNotWrittenOverByIt() throws {
        // Saved by a newer build, with a mode this one doesn't know.
        let unreadable = Data(#"[{"id": "\#(UUID().uuidString)", "word": "JSON", "replacement": "Jason", "mode": "newer"}]"#.utf8)
        let saved = [Pronunciation(word: "Kokoro", replacement: "Ko ko ro")]

        let device = try Device(synced: unreadable, saved: saved)

        #expect(device.model.pronunciations == saved)
        #expect(device.store.saves.isEmpty)
        #expect(device.store.data == unreadable)

        // An edit here still saves over it; the newer build would merge that and write back.
        device.model.pronunciations = []
        #expect(device.store.saves.count == 1)
        device.store.receive(unreadable)

        #expect(device.model.pronunciations.isEmpty)
        #expect(device.store.saves.count == 1)
    }

    @Test func comingBackToTheForegroundPicksUpWhatAnotherDeviceSavedMeanwhile() throws {
        let device = try Device()
        #expect(device.store.refreshes == 0)
        let theirs = [PronunciationRecord(Pronunciation(word: "JSON", replacement: "Jason"), updatedAt: Date())]
        device.store.arriveUnannounced(try PronunciationRecord.encoded(theirs))

        device.model.appDidBecomeActive()

        #expect(device.store.refreshes == 1)
        #expect(device.model.pronunciations == theirs.map(\.pronunciation))
        #expect(device.model.voiceLoop.pronunciations == theirs.map(\.pronunciation))
        #expect(device.store.saves.isEmpty)
    }

    @Test func twoDevicesWithListsFromBeforeSyncAgreeAndStopWriting() throws {
        let mac = try Device(saved: [
            Pronunciation(word: "JSON", replacement: "Jason"),
            Pronunciation(word: "Kokoro", replacement: "Ko ko ro"),
        ])
        // The iPhone updates later, so its own JSON is the newer one.
        let iPhone = try Device(synced: mac.store.data, saved: [
            Pronunciation(word: "API", replacement: "A P I"),
            Pronunciation(word: "JSON", replacement: "Jay-son"),
        ])

        // Each wrote its own list once, at launch.
        let saves = (mac.store.saves.count, iPhone.store.saves.count)
        #expect(saves == (1, 1))
        mac.store.receive(iPhone.store.data)
        iPhone.store.receive(mac.store.data)
        mac.store.receive(iPhone.store.data)

        let expected: Set = ["API A P I", "JSON Jay-son", "Kokoro Ko ko ro"]
        #expect(Set(mac.model.pronunciations.map { "\($0.word) \($0.replacement)" }) == expected)
        #expect(Set(iPhone.model.pronunciations.map { "\($0.word) \($0.replacement)" }) == expected)
        // In their own orders, which differ, and with nothing more to write.
        #expect(mac.model.pronunciations.map(\.word) == ["Kokoro", "API", "JSON"])
        #expect(iPhone.model.pronunciations.map(\.word) == ["API", "JSON", "Kokoro"])
        #expect((mac.store.saves.count, iPhone.store.saves.count) == saves)
    }

    @Test func anEditAndARemovalOnOneDeviceReachTheOther() throws {
        let mac = try Device()
        mac.model.pronunciations = [
            Pronunciation(word: "JSON", replacement: "Jason"),
            Pronunciation(word: "Kokoro", replacement: "Ko ko ro"),
        ]
        let macBefore = mac.store.data
        let iPhone = try Device(synced: macBefore)
        #expect(iPhone.model.pronunciations == mac.model.pronunciations)

        iPhone.model.pronunciations[0].replacement = "Jay-son"
        iPhone.model.pronunciations.remove(at: 1)
        mac.store.receive(iPhone.store.data)

        #expect(mac.model.pronunciations == iPhone.model.pronunciations)
        #expect(mac.model.voiceLoop.pronunciations == iPhone.model.pronunciations)

        // The edit and the removal stay when the store's older copy comes back round, as when
        // the Mac's write reaches iCloud after the iPhone's.
        iPhone.store.receive(macBefore)

        #expect(iPhone.model.pronunciations.map(\.replacement) == ["Jay-son"])
        #expect(try iPhone.syncedRecords().filter(\.deleted).count == 1)
    }
}
