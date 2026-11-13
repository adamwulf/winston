# Winston

A personal iOS and Mac app for talking to Claude bots over Telegram, with a text
mode and a hands-free voice mode. See [PLAN.md](PLAN.md) for the design.

## Layout

- `Package.swift`: library targets `TelegramLink` (TDLibKit wrapper) and
  `VoiceLoop` (listening, pause detection, speech, barge-in), plus their tests.
  `LogSupport` and `WinstonLogging` hold the logging (see [Logging](#logging)).
- `App/Winston.xcodeproj`: the multiplatform SwiftUI app (iOS 26+, macOS 26+).
  `App/Winston/` is a folder-synced group, so new files there join the target
  without project file edits.

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
- `TelegramLink` and `VoiceLoop` use swift-log (`Logging`) and `LogSupport`
  only. Under `swift test` their logs go to stderr.
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
  such as `app.model`, `telegram.link`, or `voice.loop`. A swift-log `Logger`
  binds to its handler when it's created, so keep loggers lazy like this.
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
