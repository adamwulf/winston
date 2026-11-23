# Winston

A personal iOS and Mac app for talking to Claude bots over Telegram, with a text
mode, a hands-free voice mode, and [push-to-talk](#push-to-talk). See
[PLAN.md](PLAN.md) for the design.

## Layout

- `Package.swift`: library targets `TelegramLink` (TDLibKit wrapper),
  `VoiceLoop` (listening, pause detection, speech, barge-in) and `WinstonCore`
  (the app's state and logic: `AppModel`, `AppSecrets`, `PhotoFiles`,
  `DocumentFiles`, `OpenedFile`), plus
  their tests. `LogSupport` and `WinstonLogging` hold the logging (see
  [Logging](#logging)). `ShareOutbox` is the hand-off to the iOS share
  extension (see [Share extension](#share-extension-ios)).
- `App/Winston.xcodeproj`: the multiplatform SwiftUI app (iOS 26+, macOS 26+).
  `App/Winston/` is a folder-synced group, so new files there join the target
  without project file edits. It holds only SwiftUI views and AppKit/UIKit
  glue, and has no tests. Anything with logic worth testing goes in a package
  target. `App/WinstonShare/` is the same for the iOS share extension target.
- `App/Winston.xcworkspace`: the app project plus the package, so the
  `Winston` scheme can run the package's tests. Open this one to test in
  Xcode. Opened alone, the project sees the package's libraries but not its
  tests. See [Xcode Cloud](#xcode-cloud).

## Setup

Copy `App/Config/Secrets.example.xcconfig` to `App/Config/Secrets.xcconfig`
(gitignored) and fill in `TG_API_ID` / `TG_API_HASH` from
<https://my.telegram.org> → API development tools.

## iOS push notifications

**Push is off for now.** Builds don't sign in the `aps-environment` entitlement until the
App ID has Push Notifications. Until then, iOS turns down every APNs token request, and
Settings → Notifications shows "Couldn't connect" with Retry. To turn push on, follow
[Turning push back on](#turning-push-back-on).

Settings → Notifications → Enable Notifications asks for permission. Winston requests
the current APNs token at launch and on activation, then registers it with Telegram once
logged in. Each launch, token or environment change, and new login registers again;
an unchanged token already registered or being registered is left alone. A failure offers Retry.
No Winston server is needed: Telegram sends ordinary APNs alerts directly to Apple.[^1]

Alerts follow the account's Telegram notification settings, including non-bot chats.
Winston does not change those cloud settings. Tapping a private bot alert selects its
chat after login and chat loading; other alerts open the app without navigating to a
group or secret chat. If Telegram includes the receiving account ID, Winston checks it
before opening the chat. Single-account payloads can omit that ID.[^2]
The current chat does not show a duplicate foreground banner. Push does not start
voice mode; background speech still requires an already active voice session.

### Turning push back on

Signing in `aps-environment` without the Push Notifications capability on the App ID
fails: no profile includes that entitlement, so local signing fails and Xcode Cloud's App
Store export fails. That happened to every build from 39 until push was turned off. Do
these steps in order. [plans/enable-push.md](plans/enable-push.md) has them in more
detail, with how to check each one.

1. In the Apple Developer account, go to Certificates, IDs & Profiles → Identifiers →
   `com.milestonemade.winston`. Check Push Notifications and Save. App Store Connect needs
   no change.
2. Refresh the provisioning profiles. Xcode Cloud's automatic signing should make new ones
   on its next build. On a Mac, sign in to Xcode → Settings → Accounts, then build to an
   iPhone with automatic signing, so Xcode makes a profile for the App ID with Push.
3. Sign the entitlement back in. The iOS app already signs in `App/Config/iOS.entitlements`
   (for the App Group, see [Share extension](#share-extension-ios)). Add to its dict:

   ```
   <key>aps-environment</key>
   <string>$(PUSH_ENVIRONMENT)</string>
   ```

   and remove the "Push is off" comment from `App/Config/Shared.xcconfig`.

4. Check that a signed Release archive succeeds and that
   `codesign -d --entitlements - <archive>/Products/Applications/Winston.app` prints
   `aps-environment`. Then push, and check that Xcode Cloud's "Exporting for App Store
   Distribution" step passes.
5. Remove the "Push is off" note above, this section, and `plans/enable-push.md`. Then
   reword Provider and signing setup step 1 to say the App ID has Push Notifications and
   the iOS target signs in `aps-environment`.
6. Finish [Provider and signing setup](#provider-and-signing-setup) steps 2 and 4: the
   APNs certificate for Telegram, and a device check.

### Provider and signing setup

1. Enable Push Notifications for `com.milestonemade.winston` and sign in the
   `aps-environment` entitlement. See [Turning push back on](#turning-push-back-on).
2. Configure APNs certificates for the same Telegram application that owns
   `TG_API_ID` at [Telegram's application settings](https://my.telegram.org/apps).
   TDLib requires the correct application platform and uploaded provider credentials.[^1]
   Telegram's certificate upload expects PEM containing both the certificate and its
   private key.[^3] Keep those provider credentials out of the app and repository.
3. `PUSH_ENVIRONMENT` in `App/Config/Shared.xcconfig` defaults to `development` for
   Debug and `production` for Release. It supplies both the entitlement and the
   environment sent to Telegram. **It must match the final signed app.** For a
   development-signed Release build, explicitly build with
   `PUSH_ENVIRONMENT=development`; for a distributed Debug build, use
   `PUSH_ENVIRONMENT=production`. Xcode export may change signing entitlements
   without changing Info.plist, so check the exported app before testing delivery.
4. Install a signed build on an iPhone, log in, enable notifications, then background
   Winston and send a message from an unmuted bot. Repeat with TestFlight to verify
   production delivery. A successful device registration is not evidence that the
   provider certificate is configured correctly.

### Verification

Package tests exercise the real TelegramLink and AppModel with fake TDLib requests:
token/login ordering, token changes during registration, retry, logout, cold-launch
navigation, account checks, and private/group payload parsing.

For a device check, test permission denial and later enabling it in iOS Settings;
tap alerts with Winston running and after termination; verify the current-chat banner
is suppressed in the foreground; and verify a locked-screen voice session separately.
With a photo/file picker or document preview open, tap another bot's alert: the
presentation should close, and a pending picker selection must not send to the new chat.
Repeat with a non-bot alert: its explanation should remain visible inline in the chat
screen after the picker or preview closes, with a working Dismiss button.
Regular APNs alerts are displayed by iOS. There is no notification service extension,
silent-push processing, or new background mode in this implementation.

### Catching up after the background

iOS suspends Winston soon after it leaves the foreground, unless a voice session keeps
it running, so a bot's message that comes while the phone is locked reaches Winston
only as an alert. The alert doesn't use the message up: Telegram keeps every update in
the account's update sequence, and TDLib fetches what it missed
(`updates.getDifference`) at startup, when the server reports a new session, and when
it sees a gap.[^4] What can hold it up is the connection, the likely cause of messages
missing after Adam opened Winston (the logs below are there to confirm it on a
device). Unless TDLib's `online` option is set, TDLib waits about 135 seconds without
hearing from the server before it gives up on a connection,[^5] and after a suspension
the connection is often dead. Winston never set it, so after Adam opened the app,
TDLib could sit on a dead connection for two minutes before catching up.

`AppModel` now sets `online` each time the app becomes active (and on login while
it is), and clears it when the app leaves the foreground: to the background on iOS,
to another app on macOS. Going online makes TDLib ping at once and give up on the
connection if no answer comes within a couple of seconds; it then reconnects and
fetches what it missed. Telegram shows Adam as online meanwhile, as its own apps do.
Each message TDLib catches up arrives as a new message, and `AppModel` shows a
message ID once however often it arrives.

To follow an alert's message through the logs (IDs and counts only), grep a log file
for `alert` (in Notification Center at activation, or the tapped one's response),
`opening notification`, `app became active`, `telegram online status set`,
`connection state changed` (`updating` is TDLib fetching what it missed),
`new message from TDLib`, `message delivered`, `message already shown`,
`message ignored`, and `chat history merged`. An alert's `messageID` is TDLib's ID for
the message, the same one the other lines show.

[^1]: [Telegram push setup](https://core.telegram.org/api/push-updates) and [TDLib device-token requirements](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1_device_token.html).
[^2]: [TDLib maintainer guidance and ordinary APNs payload examples](https://github.com/tdlib/td/issues/2613).
[^3]: [TDLib maintainer's APNs certificate format requirements](https://github.com/tdlib/td/issues/421).
[^4]: [Telegram's update handling](https://core.telegram.org/api/updates) lists when a client must fetch the difference. In TDLib 1.8.69, `Td::init` and `UpdatesManager::init_state` fetch it at startup, and `Session::on_new_session_created` feeds TDLib a fake `updatesTooLong` to fetch it after a new session.
[^5]: TDLib 1.8.69, `td/mtproto/SessionConnection.h`: `read_disconnect_delay()` and `ping_disconnect_delay()` are 135 seconds plus a random delay of up to 5 offline. `OptionManager::set_option` passes `online` to `StateManager::on_online`, and `SessionConnection::set_online` then pings at once and treats the connection as dead without an answer within `rtt()`: 1.5 times the measured round trip plus 1 second, at least 2 seconds.

## Build and test

Building needs Xcode 27 or later: the code uses the iOS 27 and macOS 27 SDKs
(Foundation Models' newer error types, behind availability checks), though it
runs on iOS 26 and macOS 26. The first package resolve downloads
TDLibFramework (about 375 MB).

```sh
swift test --build-path .build

xcodebuild -quiet -project App/Winston.xcodeproj -scheme Winston \
  -destination "generic/platform=iOS Simulator" -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -quiet -project App/Winston.xcodeproj -scheme Winston \
  -destination "platform=macOS,arch=arm64" -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

## Testing

`swift test` needs no network, microphone, speaker or Telegram account.

### What the tests run

The tests run the real code. A test process can't have eight things, and each
is reached through one seam. The seams are `package` declarations, so the app
can't see them.

| A test can't have | Seam | Stand-in, under `Tests/` |
|---|---|---|
| TDLib and a Telegram account | `TDLibRequests` and `TDLibClientSource` in `TelegramLink` | `FakeTDLib`: keeps a pretend account, walks TDLib's login states, and sends updates as TDLib's JSON |
| Permission prompts and the speech model | `requestPermissions` and `makeRecognizer` in `VoiceEnvironment`, and the `Recognizer` it makes: `start(inputs:)`, `results`, `finalize(through:)` and `cancel()` | `VoiceTestBed` and `ScriptedRecognizer`: a test says what was heard. Asked to finalize, it waits until it has read that far and reports its last volatile result again as final, as the analyzer does. It notes where the audio it is fed was loud (`soundHeard`) |
| A microphone and a speaker | `makeEngine` and `enableVoiceProcessing` in `VoiceEnvironment` | `OfflineAudio`: real `AVAudioEngine`s in offline rendering mode, with a meter on what was played |
| The Kokoro voices' 335 MB model | `KokoroEngine`, as `kokoro` in `VoiceEnvironment` | `FakeKokoro`: loads when the test says so, renders each sentence as a 0.2 s tone, keeps track of whether its model is stored, and has the dictionary words and phoneme symbols the test gives it |
| Apple's on-device language model | `PronunciationSuggester`, as `pronunciationSuggester` in `AppModel`'s package init | `FakePronunciationSuggester`: available unless the test gives a reason it isn't, answers each request with the next answer the test gave it, can hold each answer back until the test lets it go, and notes which requests were cancelled |
| A system language and installed voices it can change | `languageCode` and `systemVoices` in `VoiceEnvironment` | `VoiceTestBed`: American English and the Mac's own voices unless a test sets others, and a record of each time the loop lists the voices |
| A day going by | `now` in `VoiceEnvironment` | `VoiceTestBed.now`: stands still until a test moves it |
| The app's standard user defaults | `kokoroUnchosenSince` and `setKokoroUnchosenSince` in `VoiceEnvironment` | `VoiceTestBed.kokoroUnchosenSince`: kept in memory; a loop made later on the same bed sees it, as after a relaunch |

Everything else is the production code: the `TelegramLink` actor with its
update decoding and mapping, the `VoiceLoop` with its pipeline, converter,
player and the real `AVSpeechSynthesizer`, and `AppModel` on top of both.
`TelegramLinkTestSupport` and `VoiceLoopTestSupport` hold the stand-ins, so
every test target shares them.

`KokoroRealModelTests` runs the real model through the real `VoiceLoop`, but
only once the model is in `.build/kokoro-model` (or `WINSTON_KOKORO_MODEL_DIR`);
otherwise it is skipped. Running `LiveKokoro(directory:)` on that folder once
downloads it.

`OnDevicePronunciationSuggesterRealModelTests` runs Apple's on-device model
and prints what it suggests for a few words, for a person to judge. It is off
by default: it spends about 25 s on the model beside suites that time things,
and its answers differ from run to run. Ask for it where the model is
available, with an environment variable:

```sh
WINSTON_SUGGESTER_REAL_MODEL=1 swift test --filter OnDevicePronunciationSuggesterRealModelTests
```

or, where setting one is awkward, with a file in the package's `.build` folder,
which git ignores; delete it to turn the check off again:

```sh
touch .build/suggester-real-model
swift test --filter OnDevicePronunciationSuggesterRealModelTests
rm .build/suggester-real-model
```

`VoiceLoop.playsSoundCues` is a `package` switch as well. The sound cues (taps
when listening starts and stops, a chime for any reaction from the bot, and low
taps when the bot starts typing) would add to `playedFrames`, so
`VoiceTestBed.makeLoop()` and `Harness` leave them off, and the tests of the
cues pass `soundCues: true`. `VoiceLoop.hasPlayedWorkingCue` says whether the
typing taps have played since the bot started typing. With
`OfflineAudio.recordsOutput` on, `OfflineAudio.output` keeps every sample that
came out of the speaker, so a test can tell which sounds played together: the
working cue tests check that the taps never sound with a reply. The offline
engine resamples its output, so they tell the quiet taps from the much louder
replies and cues by level rather than sample for sample.

Rules for new tests:

- Drive the real type through its public API, and assert what it did: the
  requests TDLib received, the state it published, how much was spoken.
- Don't copy production logic into a test, and don't write a test only to run
  lines.
- New logic goes in a package target, not in `App/`.

### Coverage

```sh
Scripts/coverage.sh
```

runs the tests on macOS and prints line coverage for every file in `Sources/`.
[docs/coverage](docs/coverage/README.md) has the dated reports, how to make
one, and the goals for coverage and tests.

Five places stay uncovered on purpose, because they only call into the
system:

- `LiveVoiceEnvironment.swift`: the permission prompts, the speech model, the
  clock and the standard user defaults.
- `LiveKokoro.swift`: KokoroTTS, which downloads its model. Covered only when
  `KokoroRealModelTests` runs.
- `OnDevicePronunciationSuggester.generatedPronunciations(for:request:started:)`: Apple's
  on-device model. Covered only when
  `OnDevicePronunciationSuggesterRealModelTests` runs.
- `TDLibClientManager.makeClient` and the `TDLibClientManager()` default in
  `TelegramLink.init(config:)`: the real TDLib, which would use the network.
- A few defensive `throw`s that the system never triggers, such as
  `AudioFormatError`.

Keep new code out of `LiveVoiceEnvironment.swift` unless it is a call into
the system.

### iOS

Code inside `#if os(iOS)` isn't compiled by `swift test`: the audio session,
and what the voice loop does when a call or another app interrupts it. Run the
package tests on a simulator to cover it:

```sh
xcodebuild test -scheme Winston-Package \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -derivedDataPath DerivedData -enableCodeCoverage YES \
  -resultBundlePath DerivedData/ios-tests.xcresult

xcrun xccov view --report --files-for-target VoiceLoop DerivedData/ios-tests.xcresult
```

`Tests/VoiceLoopInterruptionTests` only has tests on iOS. The tests that need a
child process (logging bootstrap, the real `Library` folder) only run on macOS.

### Xcode Cloud

The `Winston` scheme tests with `App/Winston.xctestplan`: every test target,
with code coverage on. Xcode Cloud reaches it through the workspace, so the
workflow uses `App/Winston.xcworkspace`, with a Test action for an iOS
simulator and one for macOS, since some tests only run on one of them. Its
environment needs `TG_API_ID` and `TG_API_HASH` (mark the hash Secret), as
every workflow does: `ci_post_clone.sh` fails without them. The same run,
locally:

```sh
xcodebuild test -workspace App/Winston.xcworkspace -scheme Winston \
  -destination "platform=macOS,arch=arm64" -derivedDataPath DerivedData \
  -resultBundlePath DerivedData/macos-tests.xcresult
```

A test action runs `build-for-testing`, then `test-without-building` in a fresh
environment that has `App/ci_scripts` but not the source code. In that second
phase `ci_post_xcodebuild.sh` prints line coverage by target and file to the
build log. Each test bundle links the package code it tests, so a library's
files are listed under the bundles that test it (`Sources/VoiceLoop/` under
`VoiceLoopTests`), and a bundle's total counts its test files too. The test
action's result bundle, in the build's artifacts, opens in Xcode with the full
report.

## Opening files in Winston

Winston declares document types (`CFBundleDocumentTypes` in
`App/Config/Info.plist`: zip, PDF, images, plain text, and `public.data` for
any other file) at `LSHandlerRank` Alternate, a secondary handler. Launch
Services prefers an app that owns a type or ranks it Default, so Winston
becomes a type's default only if no such app is installed or Adam picks it.
There is no share extension and no App Group: nothing to set up in the
developer portal.

- iOS: Winston shows in the share sheet for a file (Files, Mail and Messages
  attachments), in the app row or under More. iOS hands over a copy
  (`LSSupportsOpeningDocumentsInPlace` is NO on iOS) in `Documents/Inbox`, or
  `tmp/<bundle ID>-Inbox` for some imports from Files. Winston removes that
  file, and only that one, once it is sent or cancelled. The Photos app's
  share sheet lists only share extensions, so it won't show Winston: Save to
  Files, then share from Files.
- Mac: Open With in Finder, or a file dropped on the Dock icon, which brings
  the chat window forward, even from behind Settings. Files dropped on the
  window still go straight to the chat shown, as before.

`AppModel.openFile(at:)` gives the file its place in the sheet at once, so
files go in the order they were opened, and copies it off the main actor into
`tmp/OpenedFiles` as the + button's Files does (security-scoped, coordinated,
so an iCloud Drive file downloads first; a folder is turned down). A file that
can't be copied keeps its place with the error and Try Again, without holding
up the others. Once Winston is logged in with its bot chats a sheet lists the
agents and Cancel, and asks even with one agent. A file opened before then
waits. Picking an agent sends the file there, without changing the chat
shown: a still image as a photo (a JPEG of at most 2560 px), anything else, an
animated GIF included, as a document under its own name, from a copy of
TDLib's own. Files opened together go to the same agent, in order.

A file Adam opens closes Settings and the pickers, as a notification tap does,
but never push-to-talk, which could be in a hold: the sheet waits until
push-to-talk, or an alert, closes.

Winston follows each upload until TDLib says it was sent or failed, even when
TDLib says so before its answer to the send arrives. A failure, whether TDLib
turns the file down at once or its upload fails later, brings the sheet back
with "Couldn't send *name* to *agent*" and the file kept, in its place, for
another pick. A failure in the background closes nothing: the sheet waits for
whatever is showing. Once a file is sent, or cancelled, Winston's copy and the
file iOS handed over go. Uploads aren't followed across launches: a failure
after a relaunch shows only in the chat. Logging out removes the files of
uploads under way; quitting keeps them, for TDLib to send on the next launch.
Each launch removes what opened files left at least a day ago.

The logs (`label=app.model`) say `file opened` with its type, `opened file
copied` with whether it goes as a photo or a document, `opened file handed to
telegram` with the chat, then `opened file sent`, or `opened files cancelled`.
Failures are `copying opened file failed` (then `retrying opened file copy` on
Try Again), `sending opened file failed` (turned down at once) and `opened
file upload failed` (later). At launch, `opened file leftovers removed` gives a
count, and a logout during uploads logs `opened file uploads discarded`. No
file name is logged.

## Share extension (iOS)

From the Share sheet in any app, Winston takes one image or one file: a
screenshot, a photo, a zip, a document. Its sheet lists the agents (the bot
chats), one row each, with Cancel. With one agent it still asks, so a stray tap
sends nothing. With none yet it says to open Winston first.

The extension (`App/WinstonShare/`, bundle ID `com.milestonemade.winston.share`)
can't run TDLib, so it hands off through the App Group
`group.com.milestonemade.winston`, with `ShareOutbox`:

- Each load of the bot chats saves them as the agent list. Logging out saves
  none.
- Picking an agent copies the file into the outbox with a small manifest (agent,
  name, type), then closes.
- Each time Winston becomes active, and each time its bot chats load, it sends
  the outbox the way the + button sends: an image as a photo, any other file as
  a document under its own name. Each item then leaves the outbox, sent or not;
  a failure shows its error.

So the file goes out the next time Winston is opened: an extension has no
supported way to open its app. The Mac app has no share extension; files
dropped on its chat window already go to the chat shown.

### Signing setup

Like push, an entitlement the App ID doesn't have fails signing and Xcode
Cloud's App Store export, and both iOS targets now sign in the App Group. Do
this before a signed build:

1. In the Apple Developer account, go to Certificates, IDs & Profiles →
   Identifiers → App Groups, and register `group.com.milestonemade.winston`.
2. In Identifiers → App IDs, open `com.milestonemade.winston`, check App Groups,
   choose that group, and Save.
3. Register a new App ID (App IDs → App) with the explicit bundle ID
   `com.milestonemade.winston.share`. Check App Groups and choose the same group.
4. Xcode Cloud's automatic signing makes the new profiles, for the extension
   too, on its next build. On a Mac, build to an iPhone with automatic signing.

App Store Connect needs no change: the extension ships inside the app. Both
targets take their version from `App/Config/Shared.xcconfig`, so the build
number `ci_pre_xcodebuild.sh` stamps there reaches the extension too, and the
two always match, as App Store Connect requires.

## Push-to-talk

In text mode, a long press on the mic button (or its Push to Talk
accessibility action) opens a sheet with one big button. A hold anywhere on
the sheet below a strip at its top holds the button; the strip keeps Close
and room to pull the sheet down. What is said while it is held is sent as one
🎙️ message after it is let go. Until voice mode is
listening (`VoiceLoop.canTalk`), the button is disabled and says Starting….
Close, or swiping
the sheet away, returns to text mode. Replies are spoken while the sheet is
open, as in voice mode, but not during a hold or before its message is sent,
and a press stops the one being spoken.

Turning the microphone on takes a while (the audio session, voice processing
settling for about 200 ms, the recognizer starting), and the recognizer
reports words 0.9 to 3.8 s after they are spoken (see
[the barge-in latency research](docs/research/voice-barge-in-latency.md)). So
`AppModel.setPushToTalk(_:)` runs the voice loop for as long as the sheet is
open, with `VoiceLoop.isPushToTalk` on, and a press only unmutes the
microphone. While the button isn't held, the microphone tap feeds the
recognizer silence of the same length, so its timeline runs on. The tap
decides frame by frame from when each buffer was captured, so the words spoken
right up to the release are kept, although their buffer reaches it a tenth of
a second or more later.

The release mutes the microphone at once, but results that arrive afterwards
still count: words are kept by their time in the audio, inside the hold, not
by when the recognizer reports them. The release asks the recognizer to
finalize the audio up to it (`SpeechAnalyzer.finalize(through:)`, which the
research measured reporting about 0.1 s after the call), and the message is
sent once the recognizer has reported everything up to the release: a result
reaching the release has been read, and nothing in the transcript is still
volatile. Finalizing publishes its results before it returns, but the app may
read them after, so its return alone doesn't send. If that hasn't happened 0.5
s after it returns, or 4 s after the release, the message is sent with what
was heard, and so it is if voice mode stops (Close right after letting go) or
the engine is rebuilt meanwhile. Nothing is sent if nothing was heard. A press
before then carries on: both holds are sent as one message.

A press plays the rising taps and a release the falling ones; opening and
closing the sheet play neither. Without echo cancellation the microphone would
hear the taps, so it stays muted until they have played, plus 0.3 s, as after
a reply.

## Kokoro voices

All the Kokoro voices share one model, chosen in settings
(`KokoroModelVariant`):

| Model | Graph | Tokens per pass | First audio (Mac) | Marker |
|---|---|---|---|---|
| Soniqo 5 s (the default) | soniqo's `kokoro_5s`, as speech-swift ships it, `aufklarer/Kokoro-82M-CoreML` | about 56 | 0.4 s | `Kokoro-82M-CoreML.downloaded` |
| Masked 5 s | `kokoro_masked_5s_fp16`, `milestonemade/Kokoro-82M-CoreML-Masked` | about 56 | 0.2 s | `Kokoro-82M-Masked.kokoro_masked_5s_fp16.downloaded` |
| Masked 10 s | `kokoro_masked_10s_fp16` | about 125 | 0.4 s | `Kokoro-82M-Masked.kokoro_masked_10s_fp16.downloaded` |
| Masked 15 s | `kokoro_masked_15s_fp16` | about 194 | about 1 s | `Kokoro-82M-Masked.kokoro_masked_15s_fp16.downloaded` |
| FluidAudio 5 s | `kokoro_21_5s` (7.3 s), `FluidInference/kokoro-82m-coreml` | about 90 | 0.5 s | `Kokoro-82M-15s.kokoro_21_5s.downloaded` |
| FluidAudio 10 s | `kokoro_21_10s` | about 130 | 0.9 s | `Kokoro-82M-15s.kokoro_21_10s.downloaded` |
| FluidAudio 15 s | `kokoro_21_15s` | about 200 | 1.3 s | `Kokoro-82M-15s.downloaded` |

Each graph renders up to a fixed length of speech per pass, and a pass costs
the same however short the sentence (the first-audio times are for a short
sentence). A sentence longer than a pass is cut into pieces, and its tone of
voice resets at each cut. FluidAudio's graphs have no speed input, so every
speech rate speaks at speed 1 with them, and they use the voice matched to each
piece's length, where soniqo's uses an average of them.

Soniqo 5 s is the default. FluidAudio's graphs sound warbly: their exports run
every LSTM over the padding as well as the text (soniqo's runs them packed,
over the text only), so a short sentence, mostly padding, speaks about 1.5 times
too fast with an unsteady pitch. The masked models are our own exports, made
with elizaOS's exporter: masked LSTMs like soniqo's, fp16, and a speed input. In
blind tests they sound at least as good as soniqo's, and Masked 15 s speaks a
long sentence in one pass.

The masked models load with `.cpuOnly`: allowing the Neural Engine made their
first load compile for it for over an hour on a Mac, and passes then ran about 5
times slower. The others load with `.cpuAndNeuralEngine`, Core ML picks where
each operation runs, and `LiveKokoro` logs it (`kokoro model placement`):
soniqo's and FluidAudio's graphs run on the CPU anyway. Reading a model's compute
plan for that log is slow (two to four and a half minutes for the masked
graphs), and holds up other loads meanwhile, so it is skipped for CPU-only
models.

`KokoroLoadTimingTests` times loads and renders for the models named in
`WINSTON_KOKORO_TIMING` or in `timing-models.txt` in the real-model folder (for
example `masked5s,masked15s`). On a Mac, with Core ML's cache warm, each masked
model loads in under a second and renders a 14-word sentence in 0.4 to 0.7 s.

`LiveKokoro` downloads the chosen model into `<Application Support>/Kokoro/`
the first time a Kokoro voice uses it, then writes its marker there once the
download is complete. Soniqo 5 s is stored in the `Kokoro-82M-CoreML` folder,
about 335 MB, including all its small voice files. The masked models share the
`Kokoro-82M-Masked` folder with their stored voices and dictionaries: about
245 MB for the first with one voice, 235 MB for each model after. FluidAudio's
models share the `Kokoro-82M-15s` folder (named when it held only the 15 s model):
about 335 MB for the first with one voice, 325 MB for each model after.

Masked and FluidAudio models download and load only the chosen voice (about
2.7 MB, with a style for each sentence length). Choosing another voice reloads
the model with it, downloading that voice if needed. A stored model loads
offline only when `voices/<voice>.json` is stored too; the marker still means
only that the model downloaded. Soniqo loads all its voices, so changing voices
needs no reload. Choosing another model loads it in place of the first, which
stays stored. A load under way finishes before a newly chosen model or voice
loads; until the chosen voice is ready, the system voice speaks.

- iOS: the app container's `Library/Application Support/Kokoro/`.
- macOS: the app is sandboxed, so
  `~/Library/Containers/com.milestonemade.winston/Data/Library/Application Support/Kokoro/`.

Choosing a system voice frees the model's memory but keeps it stored. Once no
Kokoro voice has been chosen for a day, every model's folder and marker are
deleted, and choosing a Kokoro voice again downloads the chosen model again. `KokoroModel`
records when the last Kokoro voice was unchosen in the standard user defaults,
under `kokoroUnchosenSince`. `AppModel` checks it at launch and each time the
app comes back to the foreground. A model with no record (downloaded before the
record was kept) gets a day from the first check.

KokoroTTS can't read digits, and reads an acronym its pronunciation dictionary
doesn't have as if it were a word ("API" as "ay"), so the text Kokoro is given
has numbers written as words (`KokoroNumbers`) and those acronyms spelled out a
letter at a time (`KokoroAcronyms`). An acronym the dictionary has as a word
("NASA"), or a word in capitals for emphasis ("NOT"), stays as it is.
`LiveKokoro` reads the dictionary's words from the loaded model's folder:
`us_gold.json` and `us_silver.json`, the same files in both repositories.
System voices get the text as written.

Settings → Pronunciations lists words said differently: each word, matched with
its case and only as a whole word, is replaced before anything else, so "JSON"
said as "Jason" isn't spelled out. A word is either Say As, other text every
voice says in its place, or IPA, Kokoro phonemes in Kokoro's notation (IPA with
capitals for the diphthongs A, I, O, W and Y, as in `kˈOkəɹO` for "Kokoro";
KokoroTTS drops a symbol it doesn't have). IPA is for the Kokoro voices only:
KokoroTTS takes phonemes for single lowercase words and can't forget them, so an
IPA word becomes made-up placeholder words (`PhoneticPlaceholders`), one for
each word of its phonemes so KokoroTTS can cut a long sentence between them, and
each sentence goes to Kokoro with its placeholders' phonemes, which `LiveKokoro`
adds to the loaded model with `addPronunciations` before rendering it. The
system voices get the placeholders back as the word, as written. Where sentence
punctuation that ends the word ("Yahoo!") ends a sentence in the message, it
stays after the placeholders, so the sentence still ends there; elsewhere ("Mr.
Smith") the placeholders stand for all of the word. A space keeps placeholders
apart from any letter or digit beside them ("👏👏"). Placeholders are kept by
word and phonemes for the whole run, so a reply queued before its pronunciation
was changed or removed still says what it was queued with, as a Say As reply
does.
`AppModel` saves the pronunciations in the standard user defaults, under
`pronunciations`; one saved before IPA existed is Say As.

An IPA row has a Suggest button (sparkles). It lists a few ways to say the word,
each with its phonemes, a respelling and a note, a play button, and Use, which
fills the row's IPA; Regenerate asks again, even while a request is under way.
The list asks as it shows (`PronunciationSuggestions.start()`), once though its
content shows twice on the iPhone, where the popover becomes a sheet. Its
request stops when the list is closed, replaced by Regenerate, or given up on,
but not when its content disappears: on the iPhone the first content disappears
as the sheet shows, and stopping the request then left the list loading for
good. When the suggester can't run, the
button still shows, and the list says why and what would let it: Apple
Intelligence turned off, its model not ready, or a device without it. A request
that hasn't answered after a minute is cancelled, and the list says so.
The play buttons are on only while a Kokoro voice is ready
(`AppModel.suggestionPlayback`): any other voice would say the same written word
for every suggestion. Otherwise a note says what would turn them on: choosing a
Kokoro voice, choosing a voice model (with No Model), waiting while it loads, or
retrying it after it failed. The suggester is a
`PronunciationSuggester`, so another backend can be added without changing the
settings screen: each says where its suggestions come from (`attribution`), and
the list's footer shows it. The one there is, `OnDevicePronunciationSuggester`, asks
Apple's on-device model (`SystemLanguageModel.default`; no network, no key),
which isn't there without Apple Intelligence, while it is turned off, or while
its model downloads. The model knows standard IPA far better than Kokoro's
notation, so it is asked for IPA for American English, and
`MisakiPhonemes.fromIPA` converts each answer: diphthongs to capitals (the
vowel of "say" is eɪ or eː, and a bare e is the vowel of "bed", ɛ, as the
prompt asks), r to ɹ, g to ɡ, tʃ and dʒ to ʧ and ʤ, ɚ and ɝ to əɹ and ɜɹ, o to
ɔ before an r unless marked long, syllable dots, hyphens, length marks,
slashes, tie bars and other diacritics dropped (ç stays ç), a syllabic
consonant given ᵊ, and each stress mark moved from the start of its syllable to
right before its vowel. A word written without spaces gets one word of
phonemes: a space in its IPA only breaks syllables. An optional sound in
parentheses, such as the (h) of ˈsɪbə(h)n, gives a suggestion without it and
one with it, so both can be heard. Repeats are dropped, and every symbol is
checked against the symbols Kokoro can say now (`VoiceLoop.kokoroPhonemeSymbols`):
the loaded model's `vocab_index.json`, read once as it loads, next to its
dictionary words, or misaki's US symbols while no model is ready. The check is
made each time the list shows them, so it follows the model as it loads and is
freed. A suggestion with a symbol Kokoro doesn't have says so and can't be
used. The model's IPA isn't held to IPA's symbols with a pattern guide: on
macOS 27 the guides take no character classes or anchors, and an alternation of
the symbols made a request take 36 to 104 s rather than about 2.

Each step is logged at notice level, and a failure or a timeout at warning, with
counts, sizes, token counts and error codes, never the word or what the model
wrote. `grep suggestions` on a log file shows a request through. Requests are
numbered across lists (`request=`), in both labels, so a request replaced by
Regenerate, or one still winding down after its list closed, can be told from
the next.

`label=app.suggestions` is the list. `opened` (as Suggest is tapped) has neither
a number nor a time. `shown` comes as the list shows, with `asks`: on the
iPhone a second time, right after `requested`, with `asks=false`, the list's
`latestRequest` and its `ms`. `requested` has the request's number and the
model's availability, and starts its clock. Then one of `listed`, `failed`
(also at once, when the model can't run), `timed out` or `cancelled`, and
`answer dropped` for an answer that came after the list stopped waiting, each
with `request` and `ms`. Regenerate during a request logs no `cancelled`: the
next `requested` names the request it replaced (`replacedRequest`), and that
request's answer, if it comes, is `answer dropped`.

`label=voice.suggestions` is the model, every line with `request` and `ms`
since the request reached it: `model checked`, `session created` with the
prompt's sizes, `request started`, `answer started` and `answer progress` as
the answer streams in, and one of `generated` (then `IPA converted`), `failed`
or `cancelled`.

The suggestions are often wrong, above all for names from other languages, and
change from one request to the next: play each before using it. About 1
request in 35 fails on the model's side, and settings says so; Regenerate asks
again. Its guardrails declined "Nguyen" once and answered it the other times
(nothing turns them off for a structured, `@Generable`, answer), and once it ran
on writing until the token cap cut it off.
`OnDevicePronunciationSuggesterRealModelTests` prints what the model suggests
for a few words, when asked for (see [What the tests run](#what-the-tests-run)).

## Logging

Winston logs through [swift-log](https://github.com/apple/swift-log) to a
[logfmt](https://brandur.org/logfmt) file written by
[FellerBuncher](https://github.com/adamwulf/FellerBuncher), and echoes each line
to Console.

### Where the logs live

`<Library>/Logs/Winston/app-yyyy-MM-dd.log`: one file per day (the date is
UTC), `.info` and above, kept for 7 days.

- iOS: the app container's `Library/Logs/Winston/`.
- macOS: the app is sandboxed, so
  `~/Library/Containers/com.milestonemade.winston/Data/Library/Logs/Winston/`.

FellerBuncher prunes every old `.log` file in its folder, so the logs get a
`Winston` folder of their own rather than sharing `Logs/`.

### Voice timing

Voice mode logs each step from the microphone to the transcript, and from a
reply starting to it stopping, under its own label, so
`grep label=voice.timeline` on a log file shows where the time went. Every
line has `tMs`, milliseconds since that listening session started on the
monotonic host clock, and `session`. Some lines are written after what they
describe, so sort a session's lines by `tMs` to read them in time order.
Section 5 of
[the barge-in latency research](docs/research/voice-barge-in-latency.md)
lists the lines and how to read them.

The AirPods mute and media remote command lines under `voice.loop` carry
`sinceVoiceModeStartMs`, milliseconds since voice mode started. On "input mute
changed", "input mute handler called" and "input mute notification without a
mute state", that is when the line was written, and it is their only time. On
the "remote command …" lines, it is when the main actor took the command, the
same on each of that command's lines, so an "input mute changed" between them
can show a later time. They also carry how long after its own timestamp
MediaPlayer handed the command to the app (`eventToReceiptMs`), and how long it
then took to reach the main actor (`receiptToMainMs`). Once a press has
toggled the mute, "remote command handled" adds the times from the receipt and
from the timestamp to `setInputMuted` returning and to the change being
applied: `receiptToSetMutedMs`, `receiptToAppliedMs`, `eventToSetMutedMs` and
`eventToAppliedMs`. The times from the timestamp are
left out, with `eventTimestampOnUptime=false`, when the timestamp is 0 or less
or more than a minute from the receipt: it can't be taken as on the uptime
clock then, and a time from it could give the uptime away.

### Getting them out

- Mac: Help → Open Log Folder shows the folder in Finder. Help → Export Debug
  Logs… zips it and asks where to save `Winston-Logs-yyyyMMdd-HHmmss.zip`.
- Settings → Debug Logs → Export Debug Logs… does the same on both platforms:
  a save panel on the Mac (which also has Open Log Folder there), the share
  sheet on iOS (Files, AirDrop, Mail). The zip holds every file in the folder.

### Conventions

- `WinstonLogging` is the only target that imports FellerBuncher.
  `WinstonLog.bootstrap()` runs first in `WinstonApp.init()`. Never call
  `LoggingSystem.bootstrap` yourself: FellerBuncher makes the one call, and a
  second one crashes.
- `TelegramLink`, `VoiceLoop` and `WinstonCore` use swift-log (`Logging`) and
  `LogSupport` only. Under `swift test` their logs go to stderr.
- No `os.Logger`, `NSLog`, or `print`, with one exception: if
  `WinstonLog.bootstrap` fails, FellerBuncher's pre-config buffer never drains,
  so every swift-log line for the rest of the run stays in a 1,000-record
  in-memory ring and reaches neither the file nor Console. `WinstonLog` reports
  that one failure with `os.Logger` at `.fault`. The check for stray logging
  skips that file:

  ```sh
  grep -rn -E "import os|OSLog|os_log|os\.Logger|Logger\(subsystem|NSLog|print\(" --exclude=WinstonLog.swift App/Winston Sources
  ```
- One `private static let log = Logger(label: "<area>.<feature>")` per type,
  such as `app.model`, `telegram.link`, `voice.loop`, or `voice.timeline`. A
  swift-log `Logger` binds to its handler when it's created, so keep loggers
  lazy like this.
- Never log on the audio thread or the speech synthesizer's thread. Record
  times and levels there (in an atomic or a `Mutex`), and write the line on
  the main actor, as `VoiceTimeline` does.
- Log a time only as elapsed milliseconds: since the session started (`tMs`),
  since voice mode started (`sinceVoiceModeStartMs`), or between two events.
  Never a clock reading itself: the uptime (`ProcessInfo.systemUptime`), host
  time (`mach_absolute_time`, `AVAudioTime.hostTime`), a `ContinuousClock`
  instant, or an event's own timestamp such as `MPRemoteCommandEvent`'s. They
  count from the device's start, the system boot time that the privacy
  manifest uses only to measure time within the app (reason 35F9.1), and
  Export Debug Logs shares the logs. Nor a time from an event's timestamp
  that may be 0 or on another clock: that gives the uptime away too.
- Messages are fixed strings. Values go in metadata with lowerCamelCase keys:
  `log.error("sending text failed", error.logContext(["chatID": chat.id.description]))`.
- Log every caught error that isn't rethrown, with `error.logContext(...)`. Use
  `error.logCodes(...)` instead when the description could hold a path or
  something the user typed, such as a file error, and `error.tdlibLogCodes(...)`
  (which keeps TDLib's error code) for TDLib file, upload, and database errors.
- `TelegramLinkError.tdlib` keeps TDLib's message in `logContext`'s `errorCase`
  on purpose: login and send calls return server codes such as
  `PHONE_CODE_INVALID`, which make their failures diagnosable. TDLib calls that
  involve files, uploads, or the database must use `tdlibLogCodes`, because
  their messages can hold a local path.
- Privacy: metadata holds IDs, counts, and states only. Never log message
  text, transcripts, spoken text, phone numbers, login codes, passwords, names,
  usernames, file names, URLs, or the API ID or hash. Identify chats and
  messages by their numeric IDs.
