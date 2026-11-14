# Winston

A personal iOS and Mac app for talking to Claude bots over Telegram, with a text
mode and a hands-free voice mode. See [PLAN.md](PLAN.md) for the design.

## Layout

- `Package.swift`: library targets `TelegramLink` (TDLibKit wrapper),
  `VoiceLoop` (listening, pause detection, speech, barge-in) and `WinstonCore`
  (the app's state and logic: `AppModel`, `AppSecrets`, `PhotoFiles`), plus
  their tests. `LogSupport` and `WinstonLogging` hold the logging (see
  [Logging](#logging)).
- `App/Winston.xcodeproj`: the multiplatform SwiftUI app (iOS 26+, macOS 26+).
  `App/Winston/` is a folder-synced group, so new files there join the target
  without project file edits. It holds only SwiftUI views and AppKit/UIKit
  glue, and has no tests. Anything with logic worth testing goes in a package
  target.

## Setup

Copy `App/Config/Secrets.example.xcconfig` to `App/Config/Secrets.xcconfig`
(gitignored) and fill in `TG_API_ID` / `TG_API_HASH` from
<https://my.telegram.org> → API development tools.

## Build and test

The first package resolve downloads TDLibFramework (about 375 MB).

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

The tests run the real code. A test process can't have seven things, and each
is reached through one seam. The seams are `package` declarations, so the app
can't see them.

| A test can't have | Seam | Stand-in, under `Tests/` |
|---|---|---|
| TDLib and a Telegram account | `TDLibRequests` and `TDLibClientSource` in `TelegramLink` | `FakeTDLib`: keeps a pretend account, walks TDLib's login states, and sends updates as TDLib's JSON |
| Permission prompts and the speech model | `requestPermissions` and `makeRecognizer` in `VoiceEnvironment` | `VoiceTestBed` and `ScriptedRecognizer`: a test says what was heard |
| A microphone and a speaker | `makeEngine` and `enableVoiceProcessing` in `VoiceEnvironment` | `OfflineAudio`: real `AVAudioEngine`s in offline rendering mode, with a meter on what was played |
| The Kokoro voices' 410 MB model | `KokoroEngine`, as `kokoro` in `VoiceEnvironment` | `FakeKokoro`: loads when the test says so, renders each sentence as a 0.2 s tone, keeps track of whether its model is stored, and has the dictionary words the test gives it |
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

`VoiceLoop.playsSoundCues` is a `package` switch as well. The sound cues (taps
when listening starts and stops, a chime for the bot's 👍) would add to
`playedFrames`, so `VoiceTestBed.makeLoop()` and `Harness` leave them off, and
the tests of the cues pass `soundCues: true`.

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

Four places stay uncovered on purpose, because they only call into the
system:

- `LiveVoiceEnvironment.swift`: the permission prompts, the speech model, the
  clock and the standard user defaults.
- `LiveKokoro.swift`: KokoroTTS, which downloads its model. Covered only when
  `KokoroRealModelTests` runs.
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

## Kokoro voices

All the Kokoro voices share one model, chosen in settings
(`KokoroModelVariant`):

| Model | Graph | Tokens per pass | First audio (Mac) | Marker |
|---|---|---|---|---|
| Original 5 s | speech-swift's `kokoro_5s`, `aufklarer/Kokoro-82M-CoreML` | about 56 | 0.4 s | `Kokoro-82M-CoreML.downloaded` |
| FluidAudio 5 s | `kokoro_21_5s` (7.3 s), `FluidInference/kokoro-82m-coreml` | about 90 | 0.5 s | `Kokoro-82M-15s.kokoro_21_5s.downloaded` |
| FluidAudio 10 s | `kokoro_21_10s` | about 130 | 0.9 s | `Kokoro-82M-15s.kokoro_21_10s.downloaded` |
| FluidAudio 15 s (the default) | `kokoro_21_15s` | about 200 | 1.3 s | `Kokoro-82M-15s.downloaded` |

Each graph renders up to a fixed length of speech per pass, and a pass costs
the same however short the sentence (the first-audio times are for a short
sentence). A sentence longer than a pass is cut into pieces, and its tone of
voice resets at each cut. FluidAudio's graphs have no speed input, so every
speech rate speaks at speed 1 with them, and they use the voice matched to each
piece's length, where Original uses an average of them.

`LiveKokoro` downloads the chosen model into `<Application Support>/Kokoro/`
the first time a Kokoro voice uses it, then writes its marker there once the
download is complete. Original is stored in the `Kokoro-82M-CoreML` folder,
about 335 MB. FluidAudio's models share the `Kokoro-82M-15s` folder (named when
it held only the 15 s model) with their American and British English voices:
about 410 MB for the first, 325 MB for each one after. Choosing another model
while a Kokoro voice is chosen loads it in place of the first, which stays
stored.

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

Settings → Pronunciations lists words every voice says differently: each word,
matched with its case and only as a whole word, is replaced before anything
else, so "JSON" said as "Jason" isn't spelled out. `AppModel` saves them in the
standard user defaults, under `pronunciations`.

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
