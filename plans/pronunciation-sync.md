# Sync pronunciations between the Mac and iOS apps

## What it does

The pronunciations in settings sync between Adam's devices that are signed in to the same
Apple Account. They sync through iCloud's key-value store. An edit made on one device shows
up on the other, a removal stays removed, and lists that both devices had before sync get
merged, not replaced.

Today `AppModel.pronunciations` is a JSON array of `Pronunciation` (id, word, replacement,
mode) in UserDefaults under the key `pronunciations`. The settings rows bind straight to it,
so it saves on every keystroke. The iOS app and the Mac app are one multiplatform target
with one bundle ID, `com.milestonemade.winston`, so both read the same key-value store
without any extra setup. The share extension doesn't touch pronunciations.

## Design

### Storage

`NSUbiquitousKeyValueStore`. Per Apple's reference
(<https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore>) a store
holds at most 1024 keys and 1 MB of values in all, and one value can be at most 1 MB. A
write that breaks a limit fails as a whole. Sync uses one key, `pronunciations`. A live
entry is about 150 bytes of JSON and a tombstone about 110, so 1 MB holds thousands of
entries.

### Records

A new WinstonCore type, `PronunciationRecord`, is a `Pronunciation` with two more fields:

- `updatedAt`: when the entry was last written, on the clock of the device that wrote it.
- `deleted`: true for a tombstone, an entry that was removed. Its word and replacement are
  saved blank, and its mode as Say As.

A record encodes flat, so its fields sit beside the pronunciation's:
`{"id", "word", "replacement", "mode", "updatedAt", "deleted"}`. The same JSON array of
records is saved in two places: under `pronunciations` in UserDefaults (this device's copy)
and under `pronunciations` in the key-value store (the synced copy). `AppModel.pronunciations`
stays a plain `[Pronunciation]` of the live entries in settings order, so `SettingsView` and
`VoiceLoop` don't change.

### Entries saved before sync: the first-launch time

Each device saves the first time it launches a build with sync, under
`pronunciationsFirstLaunch` in UserDefaults, and keeps that value from then on. A
saved entry with no `updatedAt` (one from before sync) decodes with that time as its
`updatedAt`, and with `deleted` false. This is the only migration.

### Stamping local edits

`AppModel.pronunciations`'s `didSet` compares the new list with the records by id:

- An entry that is new or has a different word, replacement or mode gets a new record stamped
  `updatedAt = now`.
- An entry that hasn't changed keeps its record and its stamp.
- An entry with no record in the new list becomes a tombstone stamped `now`.
- Tombstones that already exist stay.

The records are saved to both copies only if stamping changed one of them.

Records that came from sync are applied through a separate path. It sets `pronunciations`
with a flag on, so the `didSet` neither stamps nor writes anything. Stamping would make
another device's edits look like new local edits. Writing to the store from there would
send this device's order back to the other device, which differs from the order it wrote,
and the two would trade writes forever. The sync path saves the local copy itself, and
writes to the store only under the rule in "When to write back to the store".

### Merge

The merge is a pure function in a new file, `Sources/WinstonCore/PronunciationSync.swift`,
so it can be tested without iCloud:

- Records match by `id`. For each id, the newer `updatedAt` wins, and a tombstone competes
  like any other record. If the two stamps are equal, a tombstone wins over a live entry, and
  otherwise the record that compares greater on word, then replacement, then mode wins. Both
  devices therefore pick the same record.
- The merged list keeps the local order, and entries only the other side has go at the end.
  Order is not synced and only affects the settings list. Entries with the same word aren't
  expected after the dedupe below, but if two appear, the first one in the list is the one
  spoken.

Why `id` and not the word: the word field saves on every keystroke, so keying by the word
would leave a tombstone for every prefix typed ("J", "JS", "JSO").

### First sync: one dedupe by word

Two devices that each had a list before sync have different ids for the same word. The
first merge that brings in ids this device doesn't have yet collapses live entries whose
trimmed word is the same. A store that holds only this device's own records doesn't count:
before the entitlement is signed in, the store may keep this device's writes on the device,
and an early dedupe would use up the flag on nothing. The entry with the newest `updatedAt`
stays, and a tie goes to the greater id string. Each of the others becomes a tombstone
stamped `max(now, its updatedAt)`. The device then sets `pronunciationsMergedFromICloud` in
UserDefaults, so later merges don't dedupe. Deduping on every merge could tombstone a row
while it is being typed on the other device, as soon as its word happened to match another
entry. The other device runs the same dedupe on its own first merge that brings in new ids,
and because the dedupe is deterministic, both devices reach the same result.

### Pruning and size

Tombstones older than 90 days are dropped whenever the records are saved or merged. One
cost: a device that stays offline for longer than that can bring a removed entry back. With
one user and few removals, a tombstone lasts long before 1 MB matters. Before writing to
the store, the model logs an error if the data is over 1 MB, because a write over that size
fails as a whole. Quota violations reported by the store's change notification are also
logged.

### When to write back to the store

The store keeps only the last write of the whole value, so two devices writing at nearly
the same time can overwrite each other there. The fix is that each device merges and writes
back when it has entries the store lacks:

- At launch: merge the local records with the store's, save the result locally, and write
  it to the store if it differs.
- On the store's external change notification for `pronunciations`: the same.

"Differs" compares the merged records with the store's records, both pruned with the same
clock, as dictionaries keyed by id, so order is ignored. If order counted, the two devices'
different orders would make them write back and forth forever.

If the store's value can't be decoded, the device logs it and skips both the merge and the
write. One realistic cause is a newer build on the other device that saved a mode this build
doesn't know. Treating the value as empty would make this device write its own records over
it, and the newer build would write back, so they would overwrite each other forever.
(Unreadable local data is still dropped, as today.)

### Accepted costs

- Device clocks decide close calls between edits.
- A device offline for more than 90 days can bring back a removed entry (see Pruning).
- The settings order isn't synced.
- The rollout window. Entries a device had before sync get its first-launch time, so the
  second device to update stamps its old entries later than anything the first device did in
  the meantime. Suppose the first device edits a word before the second one updates. The
  first-sync dedupe then keeps the second device's older copy of that word. A word removed
  on the first device in that window comes back from the second device's copy, which has
  a different id. To avoid both, update both apps before editing pronunciations.

### The seam

A `package` protocol, `PronunciationSyncStore` (main actor): `data` (the synced value or
nil), `save(_ data:)`, and `onExternalChange(_:)`, which runs a handler each time another
device's value arrives. There are two implementations:

- `ICloudPronunciationStore` in WinstonCore wraps `NSUbiquitousKeyValueStore.default`. It
  calls `synchronize()` once at init, and observes `didChangeExternallyNotification` on the
  main queue for the `pronunciations` key, logging the change's reason. It only calls into
  the system, so it is listed with the files that stay uncovered on purpose.
- `FakePronunciationSyncStore` in `Tests/WinstonCoreTests` is an in-memory value plus
  `receive(_ data:)`, which stands for another device's write arriving.

`AppModel`'s package init takes `pronunciationSyncStore: (any PronunciationSyncStore)? = nil`.
So does the convenience `init(voiceLoop:defaults:shareOutbox:)`, which the public `init()`
goes through and which `AppModelWithoutSessionTests` uses. Only the public `init()` passes
`ICloudPronunciationStore()`, so tests and previews never touch the real store. Without the iCloud entitlement, as in an unsigned build, the real store is
expected to keep values only on this device, and step 5 checks that.

## Steps

Do them in this order. As with push (see `plans/enable-push.md`), signing in an entitlement
that the App ID doesn't have breaks signing and Xcode Cloud's App Store export. Xcode Cloud
archives both iOS and macOS, so this affects both.

### 1. Code and tests

Write `PronunciationRecord`, the merge, the dedupe and the pruning in
`PronunciationSync.swift`. Add the seam and `ICloudPronunciationStore`, and wire them into
`AppModel` as described above. Add the fake and the tests (see Tests). Without the
entitlement this changes nothing visible: the records save locally as before.

### 2. Developer portal: add iCloud to the App ID (Adam)

In the Apple Developer account, go to Certificates, IDs & Profiles → Identifiers →
`com.milestonemade.winston`. Check **iCloud**; key-value storage needs no container. Save,
and confirm when the portal warns that the profiles become invalid. Xcode Cloud's automatic
signing makes new profiles on its next build. On a Mac, build with automatic signing.

### 3. Repository: sign in the entitlement

Only after step 2.

1. Add this to the dict in `App/Config/iOS.entitlements`:

   ```
   <key>com.apple.developer.ubiquity-kvstore-identifier</key>
   <string>$(TeamIdentifierPrefix)$(CFBundleIdentifier)</string>
   ```

2. The Mac build signs in no entitlements file today: its sandbox comes from the
   `ENABLE_*` build settings. Add `App/Config/macOS.entitlements` holding only that key. Add
   it to the Config group in the project, and set `"CODE_SIGN_ENTITLEMENTS[sdk=macosx*]" =
   Config/macOS.entitlements` in the Winston target's Debug and Release configurations.

### 4. README

Add a short section on how pronunciations sync: what syncs, last write wins per entry,
tombstones and their 90 days, the first-sync dedupe, the accepted costs (with the advice to
update both apps before editing pronunciations), and the entitlement and App ID capability. Add `ICloudPronunciationStore.swift` to the files that stay uncovered on purpose,
and `PronunciationSyncStore` to the table of test seams.

### 5. Check it

- Builds: `swift test`, and the unsigned iOS Simulator and macOS builds from README → Build
  and test. Run the unsigned Mac build and check that pronunciations still save and come
  back after a relaunch.
- After step 3, the signed archives' entitlements, checked with
  `codesign -d --entitlements -`, include `com.apple.developer.ubiquity-kvstore-identifier`
  for both iOS and macOS. The Mac app also still has `com.apple.security.app-sandbox` and
  the other entitlements from the `ENABLE_*` settings, because this is the first time it
  signs in an entitlements file.
- After step 3, export both archives with `-exportArchive` and `method` =
  `app-store-connect`, as in `plans/enable-push.md` step 5. That export is the step that
  failed for push even though the archive succeeded. On the first Xcode Cloud build after
  step 3, check that "Exporting for App Store Distribution" passes for both platforms.
- On a Mac and an iPhone signed in to the same Apple Account: add, edit and remove an entry on
  each device, and check that each change reaches the other. iCloud can take up to a minute
  or so.

## Tests

The merge, dedupe and pruning are pure functions. Their tests:

- The newer record wins, whichever side has it.
- A newer tombstone removes an older live entry, and a newer edit brings back an older
  tombstone.
- With equal stamps, both devices pick the same record.
- The merge gives the same records in either order and when run again on its own result
  (order aside).
- The local order is kept, and entries only the other side has are added at the end.
- The first-sync dedupe keeps the newest entry for a word and tombstones the others, leaves
  blank words alone, and gives the same result on both devices.
- Pruning drops tombstones older than 90 days and keeps newer tombstones and every live entry.
- Records saved before sync (no `updatedAt` and no `deleted`) decode with the first-launch
  time and as live.

`AppModel` tests, with `FakePronunciationSyncStore`:

- An edit stamps only the entry that changed and writes it to the store. A removal writes a
  tombstone.
- On the first launch with saved entries, the first-launch time is saved and used as their
  stamp. A relaunch keeps the same first-launch time.
- At launch, store records newer than the local ones replace the local ones, and the store is
  written only if the local records add something.
- Another device's write reaches `pronunciations` and `voiceLoop.pronunciations` and isn't
  restamped. When nothing local is newer, the fake store records no save after it.
- A relaunch whose store holds only this device's own records doesn't dedupe and doesn't set
  `pronunciationsMergedFromICloud`. The first merge that brings in new ids does both.
- A store value that can't be decoded leaves the local records as they are, and nothing is
  written to the store.
- Two models on two fake stores: after the test passes the stores' data back and forth, both
  have the same entries and stop writing. This holds when their orders differ, and for lists
  made before sync that share a word.
- The existing tests (saved and restored in order, IPA mode, unreadable data dropped) still
  pass.
