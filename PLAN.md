# Winston: Initial Plan

Status: **draft for Adam's sign-off** (2026-11-11). Nothing is built yet.

Winston is a personal iOS app (Mac too) for talking to Adam's two Claude Code
Telegram bots. One bot runs on the daily-driver laptop, the other on the
always-on laptop at home. The app has a text mode and a hands-free voice mode.
It ships to internal TestFlight testers only. The goal is a quick win: about
2–4 focused days, kept simple. The bots stay as they are. Optional bot-side
config is listed separately at the end.

## Requirements (from Adam)

1. Send and read messages with both bots over Telegram.
2. A type mode and a voice mode, with a button to switch between them.
3. Voice mode is always listening, and it sends what Adam says after a short pause.
4. The app speaks the bots' replies.
5. The app stops speaking as soon as Adam starts talking (barge-in).
6. Adam can send photos.
7. A 👍 button puts a real Telegram reaction on the bot's latest message.
8. Reactions work both ways in the app. Adam sends 👍, and the app shows the
   reactions the bots put on his messages: the plugin's `ackReaction` and
   Claude's `react` tool.

## Key decisions

- **The app is a Telegram *user* client, not a bot.** The bots run the Claude
  Code Telegram channel plugin, which long-polls `getUpdates` with the bot
  token. Telegram allows exactly one `getUpdates` consumer per token (see the
  comment above the PID-file handling in the plugin's `server.ts`). So the app
  logs in as Adam once with TDLib: phone number, then a code, then the 2FA
  password if one is set. To the app, each bot is just a private chat, the same
  way Adam's Mac Telegram app sees it.
- **TDLibKit** (`github.com/Swiftgram/TDLibKit`) wraps Telegram's official
  TDLib for SPM. It is actively maintained: the latest release is
  `1.5.2-tdlib-1.8.69`, from 2026-11-11. It has an async/await API and supports
  iOS and macOS. The first package resolve downloads a binary of about 300 MB.
- **Telegram API credentials:** Adam creates an `api_id` and `api_hash` at
  my.telegram.org. They go in a gitignored `Secrets.xcconfig`, reach
  `Info.plist` as build settings, and the app reads them at runtime.
- **Native multiplatform SwiftUI**: one app target for iOS and macOS, no
  Catalyst. TDLibKit, Speech and AVFoundation all run on both platforms.
- **Speech-to-text:** `SpeechAnalyzer` with `SpeechTranscriber`, on-device.
  This sets the minimum OS to iOS 26 / macOS 26.
- **Text-to-speech:** `AVSpeechSynthesizer.write(_:toBufferCallback:)` renders
  speech into buffers. They play through the same `AVAudioEngine` whose input
  node has `setVoiceProcessingEnabled(true)`, so Apple's echo cancellation
  removes the app's own voice from the mic signal.
- **One Swift package with two library targets, plus a thin app.** A single
  `Package.swift` is simpler than two separate packages. Only `TelegramLink`
  depends on TDLibKit.

## Repo layout

```
winston/
├── Package.swift                 # products: TelegramLink, VoiceLoop
├── Sources/
│   ├── TelegramLink/             # TDLibKit wrapper (depends on TDLibKit)
│   └── VoiceLoop/                # listen / pause-detect / speak / barge-in (no deps)
├── Tests/
│   ├── TelegramLinkTests/
│   └── VoiceLoopTests/
├── App/
│   ├── Winston.xcodeproj         # multiplatform SwiftUI app, uses the local package
│   ├── Winston/                  # app sources (folder-synced group)
│   └── Config/
│       ├── Shared.xcconfig
│       └── Secrets.xcconfig      # gitignored: TG_API_ID, TG_API_HASH
└── PLAN.md
```

The Xcode project is a plain project that uses folder-synced groups, so new
files don't churn the `.pbxproj`. Builds go to a local `DerivedData/`, which is
gitignored.

## Package APIs (sketch)

### TelegramLink

A thin layer that turns TDLib into a few plain value types. The app never
touches TDLibKit types directly.

```swift
public actor TelegramLink {
    public init(config: TelegramConfig)                 // api_id, api_hash, database dir
    public var authState: AsyncStream<AuthState>        // .needsPhone / .needsCode / .needsPassword / .ready / ...
    public func submitPhone(_ phone: String) async throws
    public func submitCode(_ code: String) async throws
    public func submitPassword(_ password: String) async throws
    public func logOut() async throws

    public func botChats() async throws -> [BotChat]    // private chats whose peer is a bot
    public func history(in chat: ChatID, limit: Int) async throws -> [ChatMessage]
    public var events: AsyncStream<ChatEvent>           // .new, .edited, .reactionsChanged, .typing, .sendSucceeded

    public func sendText(_ text: String, to chat: ChatID) async throws
    public func sendPhoto(fileURL: URL, caption: String?, to chat: ChatID) async throws
    public func toggleReaction(_ emoji: String, on message: MessageID, in chat: ChatID) async throws
    public func markRead(_ messages: [MessageID], in chat: ChatID) async throws
}

public struct ChatMessage {     // id, chatID, isOutgoing, date, text (AttributedString),
                                // photo (local file, if any), reactions: [Reaction]
}
```

The TDLib calls behind it are `setTdlibParameters`, the `setAuthentication*` /
`checkAuthentication*` calls, `getChats`, `getChatHistory`, `sendMessage`
(with `inputMessageText` or `inputMessagePhoto`), `addMessageReaction`,
`removeMessageReaction`, `viewMessages` and `downloadFile`. The updates it
handles are `updateAuthorizationState`, `updateNewMessage`,
`updateMessageContent` (edits), `updateMessageInteractionInfo` (reactions),
`updateChatAction` (typing) and `updateMessageSendSucceeded`.

TDLib keeps its message database in Application Support. History survives
relaunches and shows up immediately on open.

### VoiceLoop

```swift
@MainActor @Observable
public final class VoiceLoop {
    public enum State { case off, listening(partial: String), speaking }
    public private(set) var state: State
    public var pauseThreshold: Duration            // default 1.2s, adjustable in settings
    public var utterances: AsyncStream<String>     // one finished utterance per pause

    public func start() async throws               // asks for mic + speech permission on first use
    public func stop()
    public func speak(_ text: String)              // queued; strips markdown/code first
    public func stopSpeaking()
}
```

Inside it:

- **One `AVAudioEngine`.** Its input node has voice processing on and feeds a
  `SpeechAnalyzer` running `SpeechTranscriber`. An `AVAudioPlayerNode` plays the
  TTS buffers.
- **`PauseDetector`** is a small pure type. It takes transcript-change events
  and the current time, and reports "utterance complete" once there have been
  no new results for `pauseThreshold`. It gets unit tests with an injected
  clock.
- **`SpokenText`** is a pure function that turns a message into speakable
  text. It drops code blocks: TDLib's `pre` entities, plus fenced blocks as a
  fallback. It strips residual markdown symbols, turns `[text](url)` into
  "text", and says bare URLs as "a link". It gets unit tests.

## Behavior

### Text mode

- One chat screen, with a two-segment picker at the top for the two bots. The
  picker lists Adam's private chats with bots, so no usernames need
  configuring.
- A message list shows bubbles, photos inline, and the reactions on each
  message. A "typing…" indicator comes from `updateChatAction`, which the
  plugin triggers on every inbound message.
- Formatting entities from TDLib (bold, italic, code, pre, links) render as an
  `AttributedString`. Plain-text messages render as-is.
- Edits update the bubble in place. The plugin's `edit_message` progress
  updates arrive this way.
- Visible incoming messages are marked read, so Adam's other Telegram apps
  don't show stale unread badges.
- The bottom bar has a text field, a photo button, a 👍 button and a
  voice/text toggle.

### Voice mode

- The voice/text toggle switches modes. Voice mode replaces the text field
  with a live transcript and a **Discard** button that drops the current
  utterance before it's sent.
- **Listening:** the mic stays on while voice mode is active. Once the
  transcript has stopped changing for `pauseThreshold`, the finished text is
  sent as `🎙️ <text>`.
- **What gets spoken:** only *new* incoming messages in the active chat. Edits
  are not spoken, because they are progress updates and Claude sends a new
  message when it finishes. Long replies arrive split into several messages
  (the plugin's 4096-character chunks), and they queue up and play in order.
  Photos are announced as "Photo" plus the caption.
- **Barge-in:** if a transcriber result with any text arrives while TTS is
  playing, the app stops speaking and clears the queue. That utterance then
  continues as a normal message to send.
  - **On the phone speaker,** echo cancellation keeps the TTS out of the
    transcript. This is the main technical risk; see Risks.
  - **With AirPods or headphones,** there is no echo path, so barge-in just
    works. One side effect: `playAndRecord` switches AirPods to the headset
    profile, which sounds lower quality. That's fine for speech.
- **Voice:** the best installed voice for the system language (Premium,
  then Enhanced, then default), with a voice picker in settings.

### Reactions

- **Outgoing:** the 👍 button toggles a 👍 on the bot's latest incoming message
  with `addMessageReaction` / `removeMessageReaction`, the same as tapping a
  tapback in Telegram. Long-pressing any message offers the same 👍 toggle.
- **Incoming:** reactions on Adam's messages (the plugin's `ackReaction`, and
  Claude's `react` tool) arrive as `updateMessageInteractionInfo` and show
  under the bubble.
- Whether Claude can *see* Adam's reactions is a separate bot-side question.
  See "Bot-side items" and Q1.

### Photos

- `PhotosPicker` with an optional caption. The image is exported to a
  temporary JPEG and sent as an `inputMessagePhoto`. The plugin already
  forwards inbound photos to Claude through its `image_path` meta field.
- Photos from the bot download with `downloadFile` and show inline.

### Login and settings

- First launch walks through the TDLib login steps: phone number, code (sent
  to Adam's other Telegram apps), then the 2FA password if he has one. The
  login state machine is the fiddliest part of the Telegram side.
- Settings has the pause threshold, the voice, and Log out.

## Milestones

| # | Milestone | Done when | Est. |
|---|-----------|-----------|------|
| M0 | Skeleton | Package and app build for iOS and macOS with `xcodebuild`, the tests run, and `Secrets.xcconfig` is wired up. Adam has an `api_id`/`api_hash`, a bundle ID and an App Store Connect record. | 0.25d |
| M1 | Text client | On a device: log in, pick a bot, see history, send and receive text, see edits live, send a photo, toggle 👍 on the latest bot message, see the bot's 👀/reactions on Adam's messages. | 1–1.5d |
| M2 | Voice with headphones | Voice mode with AirPods: speak, pause, the message is sent with 🎙️, the reply is spoken, and talking over the reply stops it. | 0.5–1d |
| M3 | Barge-in on the speaker | The same loop on the phone speaker without the app interrupting itself; tested in a quiet room and with background noise. | 0.5–1d |
| M4 | TestFlight | Archive and upload for iOS (and macOS if wanted), installed from TestFlight. | 0.25–0.5d |

## Testing

- **Unit tests:** `PauseDetector` (injected clock), `SpokenText` (markdown,
  code, links, emoji prefix), and TelegramLink's mapping from TDLibKit types
  to `ChatMessage`/`Reaction`, which are built directly in the tests. These
  run with `swift test` and `xcodebuild test`.
- **On a device:** a short manual checklist for login, send/receive, photo,
  👍, incoming ack, AirPods voice loop and speaker barge-in. Audio and echo
  cancellation can't be tested meaningfully in the Simulator.

## Risks

1. **Barge-in on the speaker (medium).** Echo cancellation might not remove
   enough TTS, and the app could interrupt itself. Mitigations, in order:
   ignore transcripts shorter than 2–3 words while speaking; lower the TTS
   volume a little. If neither is enough, barge-in on the built-in speaker
   becomes tap-to-stop, and barge-in stays automatic with headphones.
2. **Always-on mic picks up other people (low to medium).** Anything said near
   the phone in voice mode gets sent. Voice mode is an explicit toggle, and
   the live transcript plus the Discard button give Adam a chance to catch it.
   See Q4.
3. **iOS suspends the app in the background.** By default, listening and
   speaking stop when the app is backgrounded or the screen locks. See Q3.
4. **Account flagging (low).** Telegram sometimes flags accounts used through
   new, unofficial `api_id`s, mostly for spam-like automation. This app is
   one person reading and writing a few private bot chats.
5. **TDLib's footprint.** The first package resolve is a ~300 MB download, and
   the app binary is large. That doesn't matter for TestFlight.

## Bot-side items (optional, outside the app)

None of these are needed for the app to work. Each one is Adam's call.

1. **Turn on the ack reaction (config only).** Set `"ackReaction": "👀"` in
   `~/.claude/channels/telegram/access.json` on both laptops. The app then
   shows 👀 on each message as "received". It's off unless set.
2. **The 🎙️ convention (config only).** Add a line to the bots' CLAUDE.md
   on both machines: *"Messages starting with 🎙️ were spoken; reply in short
   plain prose without markdown or code blocks."*
3. **A plugin fork so Claude can see Adam's reactions.** Today the plugin
   never receives them:
   - `bot.start(...)` passes no `allowed_updates`, and Telegram leaves out
     `message_reaction` updates unless the bot asks for them.
   - There is no `bot.on('message_reaction', ...)` handler.

   The change is about 20–30 lines:
   - Pass `allowed_updates: [...API_CONSTANTS.DEFAULT_UPDATE_TYPES, 'message_reaction']`.
     Setting `allowed_updates` *replaces* the default list, so the defaults
     have to be included.
   - Add a `message_reaction` handler that checks `access.allowFrom` strictly.
     It must not reuse `gate()`, which hands out pairing codes, or
     `dmCommandGate()`, which lets anyone through in pairing mode.
   - Emit a channel notification such as `(reacted 👍 to message 123)` with
     `chat_id` and `message_id`. Optionally, keep a small in-memory map from
     sent message ID to a text snippet, so the note can say what was reacted
     to (Telegram's update carries no message text).

   Telegram's docs say bots must be admins to receive reactions, but that's
   about groups. Private chats should work, and that needs a quick test.

   Running the fork:
   - Its state stays in `~/.claude/channels/telegram/`, so the token,
     allowlist and pairing carry over.
   - It needs its own marketplace (`.claude-plugin/marketplace.json`),
     installed on both laptops, and the official plugin has to be removed
     there (two pollers on one token conflict with a 409).
   - Per the current Claude Code channels docs, a non-allowlisted channel only
     runs with `claude --dangerously-load-development-channels
     plugin:<name>@<marketplace>`. That only works in an **interactive**
     session and shows a full-screen confirmation **on every launch**; with
     `-p` or the Agent SDK the flag is ignored. A July 2026 issue also reports
     the flag doing nothing on one version unless `allowedChannelPlugins` is
     set, so it needs testing on Adam's version.

## Open questions for Adam

1. **Claude seeing reactions.** Which of these?
   - (a) Fork the plugin, described above. Claude sees real reactions. This
     needs the dev-channels flag and an interactive confirmation every time a
     bot starts. Does that fit how the always-on laptop launches its session?
   - (b) No fork. The 👍 button adds the real reaction *and* sends a "👍" text
     message, so Claude sees it as a normal message.
   - (c) No fork. The reaction is visible to Adam only, and Claude doesn't
     see it.

   If (a), I recommend a separate repo for the fork: it's TypeScript with its
   own lifecycle and marketplace.
2. **Permission prompts.** Do the bots ever send `🔐 Permission: <tool>`
   prompts? The plugin sends them with inline **Allow/Deny** buttons, and the
   request ID only exists in the button data. If the app doesn't render those
   buttons, Adam can't approve from the app. Supporting them is small: render
   the buttons and press them with TDLib `getCallbackQueryAnswer`. Voice mode
   could also read the prompt aloud. **Recommendation:** include the buttons
   if the bots ever prompt.
3. **Listening with the screen locked.** Research suggested listening only
   while the app is in the foreground. Turning on the `audio` background mode
   would let voice mode keep listening and speaking with the phone locked in a
   pocket (with AirPods). The listening has to start in the foreground, and
   iOS shows the orange mic indicator. It's mostly configuration.
   **Recommendation:** include it, since it fits the walking-around use case.
   Foreground-only is the fallback if you'd rather not.
4. **Always listening.** Is "send everything after a pause" OK, with the live
   transcript and Discard button as the safety net? The alternative is an
   optional push-to-talk. **Recommendation:** as specified, plus Discard.
5. **Mac in v1?** The plan is one multiplatform target with the iPhone tested
   first. Is the Mac a v1 TestFlight target, or just "it builds"?
6. **Minimum OS.** Is iOS 26 / macOS 26 OK? `SpeechAnalyzer` requires it.
7. **App identity.** The app name ("Winston"?), the bundle ID, and the
   developer team for signing and App Store Connect.
8. **Bot-side config.** OK to set `ackReaction: "👀"` and add the 🎙️ line to
   CLAUDE.md on both laptops? Adam can make these edits himself, or an agent
   with access to those machines can.

## Not in v1

- Push notifications while the app is closed. That needs a TDLib Notification
  Service Extension; the regular Telegram app stays installed for alerts.
- Voice commands ("thumbs up" → 👍) and wake words.
- Reaction emoji other than 👍, quote-replies, documents, and voice-note
  attachments.
- Any chats other than the bot chats.
