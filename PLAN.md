# Winston: Initial Plan

Status: **draft for Adam's sign-off** (2026-11-11). Nothing is built yet.

Winston is a personal iOS and Mac app for talking to Adam's two Claude bots
over Telegram. One bot runs on the daily-driver laptop, the other on the
always-on laptop at home. The app has a text mode and a hands-free voice mode.
It ships to internal TestFlight testers only. The goal is a quick win: about
2–4 focused days, kept simple. The bots stay as they are. The only optional
bot-side change is one instruction file, described at the end.

## Requirements (from Adam)

1. Send and read messages with both bots over Telegram.
2. A type mode and a voice mode, with a button to switch between them.
3. Voice mode is always listening, and it sends what Adam says after a short
   pause.
4. The app speaks the bots' replies.
5. The app stops speaking as soon as Adam starts talking (barge-in).
6. Adam can send photos.
7. A 👍 button puts a real Telegram reaction on the bot's latest message.
8. Reactions work both ways in the app. Adam sends 👍, and the app shows any
   reactions the coordinator puts on his messages.

## How the bots work

Both bots run **itsybitsy's Telegram integration**, not the official Claude
Code Telegram plugin. This section comes from `integration-helper` reading
itsybitsy's `src/channels/*` and `docs/telegram-reactions-attachments.md`.
None of it has been tested against live Telegram yet.

- **Transport.** `ib watch` long-polls the Bot API's `getUpdates` with
  `allowed_updates: ["message", "message_reaction"]`. Outbound messages go
  through a file-drop outbox that `ib watch` sends.
- **Routing.** One bot is one private chat, which is that machine's system
  coordinator (`@system`). There is no routing by prefix, topic or thread. Two
  bots means two independent installs, so the app needs exactly two chats.
- **Outbound, meaning what the app receives:**
  - Plain text only (no `parse_mode`).
  - Replies over 4000 characters arrive split into several messages.
  - Messages are never edited, so every update is a new message.
  - Typing indicators are best effort, about 5 seconds each, with gaps.
  - Replies can take minutes.
  - The coordinator can react to a message (`ib tgreact`), but only when it
    chooses to; there is no automatic ack.
  - Files arrive as documents by default, or as photos.
- **Inbound, meaning what the app sends:**
  - It handles text, photos (largest size, 20 MB limit), documents and
    reactions. Adam's 👍 reaches the coordinator as `Reacted 👍 to message N
    (your message): "<preview>"`, and removals are reported too.
  - Edited messages are ignored.
  - Voice notes are saved as `.ogg` files with **no** transcription, so the
    app sends its own speech-to-text as text.
  - Messages that land in one poll batch are merged into one block.
  - Exact-match slash commands (`/context`, `/clear`, `/compact`, `/restart`,
    `/respawn`) are intercepted by the bot.
- **No buttons.** There are no inline keyboards or callbacks, and permission
  prompts are never sent to Telegram. `ib ask` questions arrive as plain text.
  The only interactive prompt: if the coordinator is offline, the bot sends
  "The coordinator is offline. Start the coordinator? (y/n)" and treats the
  next message as the answer.
- **Allowlist.** It lives in `~/.itsybitsy/channels/telegram/access.json`.
  Adam's user ID is already allowed, and the app logs in as Adam.
- **Rate.** Keep bursts to about 1 message per second. The bot retries a 429
  once.

## Key decisions

- **The app is a Telegram *user* client, not a bot.** `ib watch` already
  consumes each bot token's `getUpdates`, and a second consumer gets a 409
  error. So the app logs in as Adam once with TDLib (MTProto, which doesn't
  conflict): phone number, then a code, then the 2FA password if one is set.
  To the app, each bot is just a private chat, the same way Adam's Mac
  Telegram app sees it.
- **TDLibKit** (`github.com/Swiftgram/TDLibKit`) wraps Telegram's official
  TDLib for SPM. It is actively maintained: the latest release is
  `1.5.2-tdlib-1.8.69`, from 2026-11-11. It has an async/await API and
  supports iOS and macOS. The first package resolve downloads a binary of
  about 300 MB.
- **Telegram API credentials:** Adam creates an `api_id` and `api_hash` at
  my.telegram.org. They go in a gitignored `Secrets.xcconfig`, reach
  `Info.plist` as build settings, and the app reads them at runtime.
- **Native multiplatform SwiftUI**: one app target for iOS and macOS, no
  Catalyst. TDLibKit, Speech and AVFoundation all run on both platforms.
  **Both platforms ship to TestFlight** (Adam confirmed). One bundle ID,
  `com.milestonemade.winston`, and one App Store Connect record cover both.
  The Mac build runs in the App Sandbox with the network-client and
  audio-input entitlements.
- **Speech-to-text:** `SpeechAnalyzer` with `SpeechTranscriber`, on-device.
  **The minimum OS is iOS 26 / macOS 26** (Adam confirmed).
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
    public var events: AsyncStream<ChatEvent>           // .new, .reactionsChanged, .typing, .sendSucceeded

    public func sendText(_ text: String, to chat: ChatID) async throws
    public func sendPhoto(fileURL: URL, caption: String?, to chat: ChatID) async throws
    public func toggleReaction(_ emoji: String, on message: MessageID, in chat: ChatID) async throws
    public func downloadFile(_ file: FileRef) async throws -> URL
    public func markRead(_ messages: [MessageID], in chat: ChatID) async throws
}

public struct ChatMessage {     // id, chatID, isOutgoing, date, text (plain String),
                                // attachment (photo or document), reactions: [Reaction]
}
```

The TDLib calls behind it are `setTdlibParameters`, the `setAuthentication*` /
`checkAuthentication*` calls, `getChats`, `getChatHistory`, `sendMessage`
(with `inputMessageText` or `inputMessagePhoto`), `addMessageReaction`,
`removeMessageReaction`, `viewMessages` and `downloadFile`. The updates it
handles are `updateAuthorizationState`, `updateNewMessage`,
`updateMessageInteractionInfo` (reactions), `updateChatAction` (typing) and
`updateMessageSendSucceeded`. No edit handling is needed, because the bots
never edit.

TDLib keeps its message database in Application Support. History survives
relaunches and shows up immediately on open.

### VoiceLoop

```swift
@MainActor @Observable
public final class VoiceLoop {
    public enum State { case off, listening(partial: String), speaking }
    public private(set) var state: State
    public var pauseThreshold: Duration            // default 1.2s, adjustable in settings
    public var utterances: AsyncStream<Utterance>  // one per pause: text plus alternates

    public func start() async throws               // asks for mic + speech permission on first use
    public func stop()
    public func speak(_ text: String)              // queued; strips stray markdown/code first
    public func stopSpeaking()
}
```

Inside it:

- **One `AVAudioEngine`.** Its input node has voice processing on and feeds a
  `SpeechAnalyzer` running `SpeechTranscriber`, with the
  `.volatileResults` and `.alternativeTranscriptions` reporting options. An
  `AVAudioPlayerNode` plays the TTS buffers.
- **`PauseDetector`** is a small pure type. It takes transcript-change events
  and the current time, and reports "utterance complete" once there have been
  no new results for `pauseThreshold`. It gets unit tests with an injected
  clock.
- **`SpokenText`** is a pure function that turns a message into speakable
  text. The bots send plain text, but Claude still sometimes writes markdown
  syntax and code. So it drops fenced code blocks, strips leftover markdown
  symbols, turns `[text](url)` into "text", says bare URLs as "a link", and
  shortens long file paths. It gets unit tests.

## Behavior

### Text mode

- One chat screen, with a two-segment picker at the top for the two bots. The
  picker lists Adam's private chats with bots, so no usernames need
  configuring.
- A message list shows plain-text bubbles, photos inline, documents as a
  filename row (tap to download, then Quick Look on iOS or open on Mac), and
  the reactions on each message.
- A "typing…" indicator comes from `updateChatAction`. It is best effort and
  has gaps, so the app never treats silence as a failure and has no reply
  timeout.
- Visible incoming messages are marked read, so Adam's other Telegram apps
  don't show stale unread badges.
- The bottom bar has a text field, a photo button, a 👍 button and a
  voice/text toggle. Typed messages are sent as-is, so slash commands like
  `/compact` still work in text mode.
- There is no message editing, because the bots ignore edits.

### Voice mode

- The voice/text toggle switches modes. Voice mode replaces the text field
  with a live transcript and a **Discard** button that drops the current
  utterance before it's sent.
- **Listening:** the mic stays on while voice mode is active. Once the
  transcript has stopped changing for `pauseThreshold`, it is sent as **one**
  message:
  - The message starts with `🎙️ `, the only voice signal the bot path carries.
    The prefix also guarantees a spoken message never matches a slash command.
  - If the recognizer's next-best reading of any phrase differs from the top
    one, a short `(alt: …)` follows in the same message, for example
    `🎙️ mark that red (alt: mark that read)`. It stays one message because
    messages from one poll batch are merged unpredictably. There are at most
    two alternates, and nothing is added when the readings agree. (This came
    from a real "red"/"read" mix-up that `winston` reported.)
- **What gets spoken:** every new incoming message in the active chat, in
  order. Long replies arrive split, and they queue up and play in sequence.
  Photos and documents are announced with their caption or filename. Replies
  can take minutes, so the loop just keeps listening in the meantime.
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
  with `addMessageReaction` / `removeMessageReaction`. Long-pressing any
  message offers the same 👍 toggle. The coordinator sees both adding and
  removing a reaction, with a preview of the message text. No bot changes are
  needed.
- **Incoming:** reactions the coordinator adds (`ib tgreact`) arrive as
  `updateMessageInteractionInfo` and show under the bubble. There is no
  automatic 👀 "received" ack unless the coordinator's instructions ask for
  one (see Q8).

### Photos

- `PhotosPicker` lets Adam choose one photo per message, with an optional
  caption. The image is exported to a temporary JPEG, kept well under the
  20 MB limit, and sent as an `inputMessagePhoto`. The coordinator receives
  it as `[user sent photo: <path> (N KB)]` plus the caption.
- Photos from the bot download with `downloadFile` and show inline.

### Login and settings

- First launch walks through the TDLib login steps: phone number, code (sent
  to Adam's other Telegram apps), then the 2FA password if he has one. The
  login state machine is the fiddliest part of the Telegram side.
- Settings has the pause threshold, the voice, and Log out.

## Milestones

| # | Milestone | Done when | Est. |
|---|-----------|-----------|------|
| M0 | Skeleton | Package and app build for iOS and macOS with `xcodebuild`, the tests run, and `Secrets.xcconfig` is wired up. Adam has an `api_id`/`api_hash` and a signing team. | 0.25d |
| M1 | Text client | On a device: log in, pick a bot, see history, send and receive text, send a photo, open a document the bot sent, toggle 👍 on the latest bot message and confirm the coordinator sees it, see reactions the coordinator adds. | 1–1.5d |
| M2 | Voice with headphones | Voice mode with AirPods: speak, pause, the message is sent with 🎙️ (and alternates when they differ), the reply is spoken, and talking over the reply stops it. | 0.5–1d |
| M3 | Barge-in on the speaker | The same loop on the phone speaker without the app interrupting itself; tested in a quiet room and with background noise. | 0.5–1d |
| M4 | TestFlight (iOS + Mac) | An App Store Connect record exists for `com.milestonemade.winston`; both the iOS and macOS builds are archived, uploaded and installed from TestFlight; the Mac build passes sandbox checks, and the voice loop works on the Mac. | 0.5d |

## Testing

- **Unit tests:** `PauseDetector` (injected clock), `SpokenText` (markdown,
  code, links, paths, the emoji prefix), building utterances with alternates,
  and TelegramLink's mapping from TDLibKit types to `ChatMessage`/`Reaction`,
  which are built directly in the tests. These run with `swift test` and
  `xcodebuild test`.
- **On a device:** a short manual checklist for login, send/receive, photo,
  document, 👍 seen by the coordinator, the AirPods voice loop and speaker
  barge-in. Audio and echo cancellation can't be tested meaningfully in the
  Simulator.
- **Integration facts to confirm live in M1:** reactions reaching the
  coordinator in a private chat, photo delivery, and the offline y/n prompt.
  These come from reading the code, not from testing.

## Risks

1. **Barge-in on the speaker (medium).** Echo cancellation might not remove
   enough TTS, and the app could interrupt itself. Mitigations, in order:
   ignore transcripts shorter than 2–3 words while speaking; lower the TTS
   volume a little. If neither is enough, barge-in on the built-in speaker
   becomes tap-to-stop, and barge-in stays automatic with headphones.
2. **Misheard words lead to wrong actions (medium).** This already happened
   ("red" for "read"). The mitigations are the 🎙️ tag, alternates in the
   message, and a coordinator instruction to confirm ambiguous actions from
   🎙️ messages (Q8).
3. **Always-on mic picks up other people (low to medium).** Anything said near
   the phone in voice mode gets sent. Voice mode is an explicit toggle, and
   the live transcript plus the Discard button give Adam a chance to catch it.
   See Q4.
4. **iOS suspends the app in the background.** By default, listening,
   speaking and receiving replies all stop when the app is backgrounded or the
   screen locks. Replies can take minutes, so this matters. See Q3.
5. **Account flagging (low).** Telegram sometimes flags accounts used through
   new, unofficial `api_id`s, mostly for spam-like automation. This app is
   one person reading and writing two private bot chats at about 1 message per
   second at most.
6. **TDLib's footprint.** The first package resolve is a ~300 MB download, and
   the app binary is large. That doesn't matter for TestFlight.

## Bot-side change (optional)

The bot integration needs no changes. Reactions, photos and the allowlist all
work today. The one optional change is the system coordinator's instructions
in `~/.itsybitsy/agent-types/system-coordinator.md` **on both machines**. Its
body is injected at session start, so the coordinator needs a respawn after
the edit. This is Adam's file (see Q8). Suggested text:

> Messages beginning with 🎙️ were spoken and your reply will be read aloud.
> Reply via `ib tgsend` in 1–3 short plain sentences: no markdown, code,
> links, lists or paths. Put any detail in a separate message. A 🎙️ message
> may include `(alt: …)` with another reading of what was heard. If an
> action is ambiguous or could be misheard, confirm before acting.

Optional extra line: *"React 👀 (`ib tgreact`) to each message when you start
working on it."* This gives the app a visible "received" signal. The
coordinator issues it on a best-effort basis, so the app only displays it and
never depends on it.

## Questions for Adam

### Resolved

- **Q1, Claude seeing reactions:** works today. itsybitsy delivers Adam's
  reactions to the coordinator, so no fork is needed.
- **Q2, permission prompts and buttons:** none exist. Approvals never go to
  Telegram, and there are no inline buttons.
- **Q5, Mac:** both iOS and Mac ship to TestFlight.
- **Q6, minimum OS:** iOS 26 / macOS 26.

### Open

3. **Listening with the screen locked.** Turning on the `audio` background
   mode keeps voice mode listening, speaking *and receiving replies* with the
   phone locked in a pocket (with AirPods). The listening has to start in the
   foreground, and iOS shows the orange mic indicator. It's mostly
   configuration. **Recommendation:** include it. Replies take minutes, so
   foreground-only would miss most of them.
4. **Always listening.** Is "send everything after a pause" OK, with the live
   transcript and Discard button as the safety net? The alternative is an
   optional push-to-talk. **Recommendation:** as specified, plus Discard.
7. **Signing team.** Which Apple Developer team should own
   `com.milestonemade.winston`? The Allume membership (apple@allume.com)
   expires around Dec 4. If it's that team, renew it before M4. A separate
   Milestone Made team works too if one exists. This blocks M4 only.
8. **Coordinator instructions.** OK to add the 🎙️ text above, and optionally
   the 👀-on-receipt line, to `system-coordinator.md` on both machines? Who
   makes the edit and the respawn?
9. **Offline prompt.** The bot sometimes sends "The coordinator is offline.
   Start the coordinator? (y/n)". It accepts only a whole message of
   `y`/`yes`/`n`/`no` (any case), so "🎙️ yes" or a merged batch just
   re-prompts. The proposal:
   - When that exact text is the latest bot message, the prompt is
     *pending*. The app shows **Yes / No** buttons that send a bare `y` or
     `n`.
   - In voice mode, the app speaks the prompt. A spoken "yes" or "no" is sent
     as a bare `y` or `n`, with no 🎙️ prefix and no alternates.
   - Any other message is held, not sent, until the prompt is answered.

   **Recommendation:** yes. It's small.

Also needed before M1: an `api_id` and `api_hash` from my.telegram.org.

## Not in v1

- Push notifications while the app is closed. That needs a TDLib Notification
  Service Extension; the regular Telegram app stays installed for alerts.
- Voice commands ("thumbs up" → 👍) and wake words.
- Reaction emoji other than 👍, quote-replies, sending documents or voice
  notes, and multi-photo albums.
- Any chats other than the two bot chats.
