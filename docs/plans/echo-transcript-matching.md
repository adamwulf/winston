# Voice mode: stop the reply's echo coming back as Adam's message

Status: written 2026-11-15; "Dropping transcripts that match the reply" was
built 2026-11-16 (`ReplyEcho`, and `VoiceLoop.apply` and `isEchoAfterReply`).
It differs from the design below in its matching rule, and where the design
said to judge the whole candidate and to consume through a result's end; those
sections now say what was built, and "Limits" says what that changes. Echo
matching applies to hands-free listening only: push-to-talk, added after this
plan, is unchanged.
The iPhone's logs have since been read
(`docs/research/echo-cancellation-regression.md`).

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
  apostrophes dropped ("I'm" becomes "im"). As built, these are
  `Utterance.words(of:)`, which also drops filler words ("uh", "um") and reads
  "okay" as "ok". The reply is matched as it was spoken: the text
  `SpeechPlayback.text` holds, after markdown stripping and pronunciations.
- **Rule (as built):** echo is a stretch of the reply, in order, and usually
  recognized clearly. Heard text of `n` words is aligned (longest common
  subsequence, exact word equality) with every run of `n + 2` consecutive
  reply words, and the best run counts. It is echo when at least two thirds
  of its words, rounded up, align: one word must be a reply word, two must
  both be, near each other in the reply, and 6 need 4. Empty text is never
  echo. The design's rule, at least half aligned anywhere in the reply, was
  built first and replaced: a long reply holds most common words, so short
  interruptions ("hold on", "wait what") counted as echo and were dropped.
- **Readings:** check the result's text and each of its alternatives
  (`TranscriptPiece.alternatives`). It's echo if any reading is. That is what
  catches "Hey" for "Hi": the recognizer often lists the other reading.
- **What is judged (as built).** The design said to judge everything heard
  since the reply started. The code didn't hold that: ignored results are
  never applied to the transcript, so the candidate was only the current
  result. Judging everything heard would also mean Adam's words had to
  outnumber the echo before he could interrupt. As built, each result is
  judged on the words it adds after the echo already judged: a result judged
  echo has its audio consumed through its last word, so the next result,
  which repeats those words, is trimmed to what follows them. A single
  misheard word is still echo when one of its alternatives matches.

Example: "Hey Adam, I can hear you loud and clear" against "Hi Adam, I can
hear you loud and clear..." aligns 8 of 9 words, at least the 6 needed.
"Wait, stop" aligns none. "Hold on" against a reply that says "on" aligns 1
of 2, not echo. "Wait, can you say that again" against a reply that says
"can", "you" and "that" far apart aligns at most 2 of 6 in any run of 8.

### While a reply plays

In `VoiceLoop.handle(_:)`, in the branch for `currentSpeech != nil` with echo
cancellation on, before the word-count check: if the candidate is echo of
`currentSpeech.text`, ignore it. That means
`timeline.resultIgnored(reason: "echo", ...)` and `ignoredResultsThisReply += 1`.

As built, it doesn't set `ignoredWhileSpeaking`, as the plan first said it
should. That flag makes `consumeEcho()` consume all the audio fed so far when
the reply ends, which would also drop words Adam says near the end of the reply
before the recognizer reports them. Late results for the echo are dropped by
the check after the reply instead (below).

The echo's audio is consumed at once, through the end of its
last word by the words' `audioTimeRange`, not through the result's range: a
volatile result's range runs on to the audio fed so far, which can hold the
start of a word Adam begins after the echo. Later results for the echo, its
final among them, then can't bring it back, during the reply or after a
barge-in, and a barge-in keeps only the words after it.

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

As built, the drop consumes through the end of the result's last word, as
during a reply, not through the result's end. It applies only in hands-free
listening with echo cancellation: without echo cancellation the half-duplex
margin already covers it, and in push-to-talk a press consumes all the audio
fed up to it, so what a hold hears is Adam's.

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
  isn't sent. (Built with an echo that meets the two-thirds rule, "Hey Adam I
  can hear you"; see "Limits". Also built: a misheard echo word whose
  alternative matches doesn't cut the reply off, and Adam talking over a reply
  after its echo was ignored interrupts it with only his words sent, also when
  the echo's volatile result ran past its last word into his first. Also
  built: "hold on" over a reply that says "on" interrupts it and is sent, and
  a barge-in like "wait, can you say that again" over a reply with "can",
  "you" and "that" far apart is sent, not dropped as its echo.)
- These existing tests still pass unchanged:
  `talkingOverAReplyStopsItAndBecomesTheNextUtterance`,
  `wordsSpokenAsAReplyEndsAreKept` ("Thanks." isn't in "Hi."), and the two
  half-duplex tests.

## Limits

- **A misheard first word can still cut a reply off.** If the first result is
  one word that matches neither the reply nor an alternative, it still
  interrupts. So does a two-word echo with one misheard word and no matching
  alternative, since two heard words must both match. The echo that follows
  is dropped, with the words that cut the reply off, only if a later result
  whose first new word starts no later than 0.5 s after the cut-off, read
  with the utterance so far, meets the two-thirds rule. "Hi Adam" heard first
  as "Hey", then finally as "Hey Adam" with no matching alternative, is only
  1 of 2 and is sent. Either way the rest of the reply is lost. Resuming a
  reply after a false barge-in, as LiveKit Agents does, would be a separate
  change.
- **Adam repeating the reply's words.** Words that repeat the reply in order
  won't count as interrupting while it plays, and won't be sent if they start
  within the margin after it ends.
- **A one-word interjection in the reply (as built).** Each result is judged
  on the words it adds, often one or two, and a long reply holds most common
  words. A result that adds only "no", "yes" or "okay" while the reply says
  that word is ignored as echo, and its audio is consumed, so the word is
  dropped for good; Adam interrupts with the next result whose new words
  aren't a stretch of the reply, and his message starts there. Two words must
  both be in the reply, near each other, so "hold on" or "stop that" over a
  reply that says "on" or "that" somewhere interrupts.
- **Right after a barge-in (as built).** A barge-in ends the reply like any
  other ending, so for a moment after it Adam's own words are judged against
  the reply too: everything he said in a result whose first word starts within
  0.5 s of the barge-in, including the words that interrupted. They are
  dropped as echo only if two thirds of them are a stretch of the reply, which
  his own words rarely are unless he repeats it. The check is there for the
  barge-in that is itself echo (a misheard first word): the echo that follows
  it is a stretch of the reply, and is dropped with it.
- **Numbers and acronyms.** The reply's text keeps digits and acronyms as
  written; Kokoro spells them out when it speaks, and the transcriber may write
  them either way. A mismatch there counts as a word that doesn't align.
- **Echo mixed with real speech (as built).** Echo judged in earlier results
  is consumed, so it neither holds back Adam's words nor ends up in his
  message. Only echo first reported in the same result as his words is mixed
  with them: that result interrupts unless two thirds of it is a stretch of
  the reply, and the echoed words are then sent with his.
- **The previous reply's tail.** A reply that starts as soon as the last one
  ends judges what it hears against itself only, so the last reply's echo,
  reported late, can still interrupt it. That was so before as well.

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
