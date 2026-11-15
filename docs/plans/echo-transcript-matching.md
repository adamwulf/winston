# Voice mode: stop the reply's echo coming back as Adam's message

Status: plan only, 2026-11-15. Nothing here is implemented. Adam asked for the
recommendation to be written down and picked up later.

## The report

On the iPhone, a reply leaked through echo cancellation and came back as a
user message. The bot sent "Hi Adam, I can hear you loud and clear..." and the
loop sent back "Hey Adam, I can hear you loud and clear." as if Adam had said
it. In the same test, one reply behaved and one didn't.

The phone's logs were not read: the agent that investigated couldn't reach
them. Everything under "How the echo becomes a message" is inferred from the
code; the log checks at the end would confirm or correct it.

## How the echo becomes a message

Two paths in `VoiceLoop`, both possible with echo cancellation on:

1. **During a reply.** `VoiceLoop.handle(_:)` treats any result with at least
   `bargeInMinimumWords` words (default 1) as Adam talking over the reply. It
   stops the reply, keeps the words as the start of the next utterance, and
   `checkForPause()` sends them after the pause threshold (1.2 s). If the
   reply's own voice gets past echo cancellation and is recognized, it cuts
   the reply off and is sent as Adam's message. Results arrive about a second
   after their audio (`.fastResults`), so by the time the barge-in fires, a
   second or more of the reply is already in the transcript.
2. **After a short reply.** If nothing was ignored while the reply played,
   `consumeEcho()` consumes nothing when echo cancellation is on, so words
   spoken just as a reply ends are kept (the test
   `wordsSpokenAsAReplyEndsAreKept` checks this). A reply shorter than the
   recognizer's delay can end before its echo is reported. The echo then
   arrives as an ordinary result and is sent.

"Hi Adam, I can hear you loud and clear" reads like the first reply of a
session, which fits Apple's description of the start of playback leaking
(below). That is a guess until the logs say which reply it was.

## How voice processing's echo cancellation works

- **The reference is everything the engine plays.** Speech and sound cues go
  through the main mixer to the output node, which is the voice-processing
  unit once `enableVoiceProcessing` has run on the input node (`Pipeline.init`,
  `Pipeline.connectOutputForVoiceProcessing`). The canceller subtracts its
  estimate of that output's echo from the microphone.
- **It converges on real playback, in about 200 ms.** An Apple engineer, in
  the accepted answer to "Acoustic Echo Cancellation does not work initially"
  ([thread 829784][apple]), says: "The echo cancellation algorithm requires a
  short convergence period before it can achieve effective suppression
  (typically >20 dB). Under normal conditions, this convergence should complete
  within approximately 200ms". Their suggested fix is to "gradually ramp up your
  playback audio volume at the start of the greeting ... you give the AEC
  algorithm time to converge before the full audio signal is present". The
  filter converges on the quiet start of the audio itself.
- **It learns only while something plays.** Apple doesn't document its
  algorithm. WebRTC's open-source canceller (AEC3) adapts its filter only
  during render (playback) activity: a commit note says "the adaptation is
  just perform during render activity" ([commit][webrtc-commit]), and
  `aec_state.cc` counts filter adaptation only for blocks with active render
  ([aec_state.cc][webrtc-aec-state]). Adaptive filters in general update in
  proportion to the reference signal, so a reference of zeros teaches them
  nothing.
- **Converged is not silent.** "Typically >20 dB" of suppression on the
  iPhone's loudspeaker, a few centimetres from its microphone, can leave echo
  that `SpeechTranscriber` still understands. A fix aimed only at the first
  200 ms wouldn't cover that.
- **Not known:** whether the filter keeps its state across seconds or minutes
  of silence, across `Pipeline.restartEngine()` (on the iPhone every new engine
  stops once right after starting and is restarted), or after the phone is
  moved. Apple's thread doesn't say.

### What was tried before

- `a4bff61` faded each reply in over 200 ms, as Apple suggests.
- `01c8892` made the fade shorter at faster speeds.
- `64f2e6f` put silence before a Kokoro reply's first sentence, only so the
  fade ended before the first word. The silence was never meant to help echo
  cancellation by itself.
- `1b0a6f5` removed both. The fade cut off the first syllables of replies and
  made sentences hard to understand.

**Constraint from Adam:** nothing may clip or attenuate the start of speech.
No fade.

## Options considered

### Leading silence: won't help

Playing silence before a reply gives the canceller no reference energy to
adapt on, so the first word still reaches a filter that hasn't converged, at
full volume. The only effect is a later start. Adam reached the same view.

### Keeping the filter warm: possible, unproven

The engine and voice processing already run from the moment listening starts,
so the output path is running; it renders silence, which warms nothing (see
above). Warming the filter needs real sound across the speech band, roughly
100 Hz to 4 kHz and up.

The start cue, `SoundCue.listeningStarted`, already plays through the
canceller before the first reply. It is three 30 ms sine taps on A5, C♯6 and
E6 (880 to 1319 Hz, with a little of each octave), 170 ms in all, at a level of
0.2. That is narrowband and brief, so it teaches the filter little about the
speech band.

A fuller start cue could converge the filter before the first reply. See "The
start-cue experiment" below. It would only help if the filter keeps its state
until the reply, which isn't documented, and it can't be tested offline: the
test engine renders offline and has no voice processing.

### Dropping transcripts that match the reply: recommended

Recognize the reply's own words when they come back and ignore them instead of
treating them as Adam. It doesn't touch the audio, so nothing clips the start
of speech. It covers a filter that hasn't converged and leftover echo after
convergence alike, and the scripted recognizer can test it offline.

## The recommended design

### Matching

A small pure type, for example `ReplyEcho` in a new
`Sources/VoiceLoop/ReplyEcho.swift`, built from a reply's text:

- **Words:** lowercased, split on anything that isn't a letter or digit, with
  apostrophes dropped ("I'm" becomes "im"). The reply is matched as it was
  spoken: the text `SpeechPlayback.text` holds, after markdown stripping and
  pronunciations.
- **Rule:** align the heard words with the reply's words in order (longest
  common subsequence, exact word equality). The heard text is echo when at
  least half its words align. A one-word result must match a reply word
  exactly. Empty text is never echo.
- **Readings:** check the result's text and each of its alternatives
  (`TranscriptPiece.alternatives`). It's echo if any reading is. That is what
  catches "Hey" for "Hi": the recognizer often lists the other reading.
- **Judge the whole candidate, not each new increment.** During a reply the
  transcript stays empty (a reply only starts when it is empty, and ignored
  results don't change it), so the candidate is everything heard since the
  reply started. More words give a steadier ratio. Judging each ~1 s increment
  on its own would trip on single misheard words.

Example: "Hey Adam, I can hear you loud and clear" against "Hi Adam, I can
hear you loud and clear..." aligns 8 of 9 words. "Wait, stop" aligns none.

### While a reply plays

In `VoiceLoop.handle(_:)`, in the branch for `currentSpeech != nil` with echo
cancellation on, before the word-count check: if the candidate is echo of
`currentSpeech.text`, ignore it as the too-few-words case does. That means
`timeline.resultIgnored(reason: "echo", ...)`, `ignoredWhileSpeaking = true`
and `ignoredResultsThisReply += 1`. `consumeEcho()` then consumes the audio fed
so far when the reply ends, so the echo's late final results aren't sent.

Without echo cancellation nothing changes: every result is already ignored
while a reply plays, and the half-duplex margin is consumed afterwards.

### After a reply ends or is cut off

Keep the last reply's matcher and the fed-audio time it ended
(`pipeline.fedAudio.time`). Set it on every ending: finished, stopped, and
barge-in. Clear it when the next reply starts and on teardown.

In `handle(_:)` with no reply playing: if a result's first new word starts
before that end time plus a margin, and the candidate is echo of the last
reply, drop it. Discard the transcript, which also removes the words of a
barge-in that was itself echo, and consume through the result's end. Find the
word's start with `Transcript.start(of:startingAt:)`, falling back to the
result's range start when there are no word timings. Start the margin at
0.5 s: echo reaches the tap a buffer and the output latency after it plays,
and a match is required as well. Once a result starts after the window, clear
the last reply; no more echo can come from it.

Log the drop as `resultIgnored(reason: "echoAfterReply", ...)`. Counts only,
never text, as the logging rules require.

### Docs to update with it

- `VoiceTimeline.resultIgnored`'s doc comment lists the reasons.
- `docs/research/voice-barge-in-latency.md`, section 5, row 8 lists them too.
- `VoiceLoop.ignoredWhileSpeaking` and `bargeInMinimumWords` describe when
  echo is consumed and what interrupts a reply.

### Tests

Unit tests for the matcher:

- An exact echo, and an echo with one misheard word, both count.
- Words not in the reply ("Wait, stop") don't.
- One word in the reply counts; one word not in it doesn't.
- Case and punctuation don't matter. Empty text isn't echo.
- Words out of the reply's order align less.
- An alternative reading that matches makes it echo.

Loop tests, in `BargeInTests` with `VoiceTestBed` and `ScriptedRecognizer`:

- The reply's own words heard during it don't interrupt it. It plays to the
  end, and neither those results nor their late final is sent.
- The echo of a short reply, first reported after it ended, isn't sent; words
  heard later still are.
- A reply cut off by one misheard word ("Hey") whose echo follows: the echo
  isn't sent.
- These existing tests still pass unchanged:
  `talkingOverAReplyStopsItAndBecomesTheNextUtterance`,
  `wordsSpokenAsAReplyEndsAreKept` ("Thanks." isn't in "Hi."), and the two
  half-duplex tests.

## Limits

- **A misheard first word can still cut a reply off.** If the first result is
  one word that matches neither the reply nor an alternative, it still
  interrupts. The echo that follows won't be sent, but the rest of the reply is
  lost. Resuming a reply after a false barge-in, as LiveKit Agents does, would
  be a separate change.
- **Adam repeating the reply's words.** Words that repeat the reply in order
  won't count as interrupting while it plays, and won't be sent if they start
  within the margin after it ends.
- **Common short words.** A one-word interruption that happens to be in the
  reply ("no", "yes") is ignored. Saying more tips the ratio and interrupts,
  with all the words kept, because nothing is consumed during the reply.
- **Numbers and acronyms.** The reply's text keeps digits and acronyms as
  written; Kokoro spells them out when it speaks, and the transcriber may write
  them either way. A mismatch there counts as a word that doesn't align.
- **Echo mixed with real speech.** If the echo leaks while Adam talks over the
  reply, the candidate holds both. His words have to outnumber the echo's
  before it counts as an interruption, and his message then includes the
  echoed words.

## The start-cue experiment

Try it if the logs show failures only on the first reply of a session (or the
first after an engine restart). That pattern would mean a converged filter
holds and only the first playback leaks.

- Give `SoundCue.listeningStarted` broadband content at a normal level for
  about 200 to 300 ms, for example a soft filtered-noise swell or a richer
  chord with many partials, instead of three 30 ms sine taps. It would sound
  different; Adam decides whether that's acceptable.
- Judge it from the logs over several sessions: compare first replies'
  `micPeakDb` and barge-ins with and without the new cue.
- It can't be checked offline, and it doesn't replace transcript matching,
  which also covers echo after convergence.

## Log checks

Export the logs:

- **iPhone:** Settings, then export logs to the share sheet.
- **Mac:** the Help menu or Settings (`DebugLogs.export()`).

Put the zip where the agent can read it, such as its worktree. Then filter
with `grep label=voice.timeline` and sort each session's lines by `tMs`. Look
for:

| Question | Lines and keys |
|---|---|
| Was echo cancellation on? | "voice mode started" and "timeline started": `echoCancellation`; "voice mode started" and "audio engine restarted": `voiceProcessing` (read from the engine, so a restart that lost it shows) |
| Which reply failed? | "speech started": `reply` (`reply=1` is the session's first) |
| Did echo trigger a barge-in? | "barge-in decided" with `replyMs`; "reply ended" with `reason=bargeIn` |
| Or did it arrive after the reply? | "first result" after "speech finished", with `wordStartMs` inside the reply |
| How loud was the leak? | "reply ended": `micPeakDb`, success against failure (only meaningful for a reply that played to the end in a quiet room) |
| What was the route? | "voice mode started": `route`, `sessionMode` |

## Sources

- Apple Developer Forums, "Acoustic Echo Cancellation does not work
  initially", thread 829784, accepted answer: [link][apple]
- WebRTC commit note on AEC3 adapting only during render activity:
  [link][webrtc-commit]
- WebRTC `aec_state.cc`, active-render and filter-adaptation counters:
  [link][webrtc-aec-state]
- `docs/research/voice-barge-in-latency.md`: result latency, `.fastResults`,
  and the voice timeline's lines.

[apple]: https://developer.apple.com/forums/thread/829784
[webrtc-commit]: https://webrtc.googlesource.com/src/+/36c69d511458f766e84d8d0cfa23ef0fda4c364e%5E
[webrtc-aec-state]: https://webrtc.googlesource.com/src.git/+/2a8231063ca50aaa72cb6ea11cb19af067112ea1/modules/audio_processing/aec3/aec_state.cc
