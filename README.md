# Winston

A personal iOS and Mac app for talking to Claude bots over Telegram, with a text
mode and a hands-free voice mode. See [PLAN.md](PLAN.md) for the design.

## Layout

- `Package.swift`: library targets `TelegramLink` (TDLibKit wrapper) and
  `VoiceLoop` (listening, pause detection, speech, barge-in), plus their tests.
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
