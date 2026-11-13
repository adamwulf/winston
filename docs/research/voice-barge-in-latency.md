# Voice mode: why words arrive seconds late, and how to stop speaking at once

Research only, 2026-11-13. No app code was changed. Measurements were made on
a Mac (macOS 27.3, Xcode SDK 27.2) with a throwaway script; nothing here has
been measured on an iPhone or with a real voice.

Since then, `.fastResults` has been turned on (half of step 2; not
`prepareToAnalyze`) and the timeline logging of step 1 has been added.
Sections 1 and 2 describe the app as it was before; section 5 describes the
logging as built.

## Summary

- **The delay is the speech recognizer, not the app's logic.** Barge-in fires
  only when `SpeechTranscriber` reports a word[^1], and with the options the
  app uses, the transcriber delivers results only about every 3.8 to 3.9 s of
  audio. Measured first-word delay: 0.9 to 3.8 s after speech starts, depending
  on where the speech falls in that block (section 2).
- **One option cuts it to about 0.9 s.** `SpeechTranscriber` has a
  `.fastResults` reporting option that the app doesn't pass[^2]. With it,
  results came about every 0.9 to 1.0 s and the first word arrived 0.9 s after
  speech started. That is still not "immediate".
- **Immediate needs a voice-activity detector (VAD), not words.** Detecting
  that someone is talking should take 100 to 200 ms (an estimate, not
  measured); recognizing a word took about a second at best.
- **Recommendation:** drive barge-in from a VAD on the echo-cancelled
  microphone tap, in two stages: fade out and pause the reply as soon as voice
  is heard, then stop it for good when the transcriber reports a word (or the
  voice keeps going), and resume it if nothing follows. Start with the loudness
  detector the app already has, made echo-aware; move to Silero VAD if device
  logs show it pausing on noise. **Fallback**, if the speaker's echo defeats
  any detector: word-based barge-in with `.fastResults` on the speaker (about
  1 s), and the VAD only on headphones (section 4).
- **A second bug-like path:** a reply can *start* playing while Adam has
  already been talking for seconds, because "is he talking?" is also judged
  from the transcript[^3]. The same VAD fixes it.
- Section 5 lists the logging to add so one app run shows the whole timeline.

## 1. What the app does today

### From microphone to "stop speaking"

1. The microphone tap asks for 4096-frame buffers[^4]. Each buffer is measured
   for loudness, converted to the analyzer's format, and queued for the
   recognizer[^5].
2. The recognizer is a `SpeechAnalyzer` running one `SpeechTranscriber` with
   the reporting options `.volatileResults` and `.alternativeTranscriptions`
   and no others[^2]. The analyzer is started without `prepareToAnalyze`[^6].
3. Results reach `VoiceLoop.handle(_:)` on the main actor[^7].
4. If a reply is playing, `handle(_:)` interrupts it only when echo
   cancellation is on and the candidate transcript has at least
   `bargeInMinimumWords` words (default 1, and the app model never changes
   it)[^1][^8]. It then clears the queue and calls `silence(...)`, which
   cancels the playback, stops the synthesizer and calls `player.stop()`[^9].
5. Without echo cancellation the loop is half-duplex: nothing spoken interrupts
   a reply[^1].

So the time from "Adam starts talking" to "the reply stops" is the time until
the transcriber's first result that contains a word, plus a few milliseconds.

### What the loudness detector does today

`VoiceActivityDetector` already runs in the tap: a buffer counts as voice when
its RMS is 3 times the running noise floor and above about -50 dBFS, for 2
buffers in a row[^10]. Its only use is to keep an utterance open: a 100 ms
timer asks whether voice was heard and restarts the pause clock[^11]. It never
stops a reply.

### Where the 4 to 5 s comes from

Measured, with the app's exact transcriber options (section 2): results arrive
in bursts at the end of blocks of about 3.8 to 3.9 s of audio. A word spoken
just before a block ends shows up in under a second; a word spoken just after
one ends waits almost the whole block. Four samples: 0.93, 3.79, 3.63 and
2.59 s.

That accounts for up to about 3.8 s on clean audio. The rest of Adam's 4 to
5 s is **not explained by measurement**. Candidates, none measured:

- A first word that straddles a block boundary may only be reported with the
  next block.
- The tap delivers audio in buffers, so up to a buffer late. The header says
  the supported tap size is 100 to 400 ms, so the 4096 frames requested (85 ms
  at 48 kHz) is below the minimum[^12]. The real size was not measured.
- While a reply plays, voice processing may attenuate the near-end voice
  (double talk), so the first words are recognized later.

### What does not cause it

- **Pause timers.** `PauseDetector` only decides when to *send* an utterance.
  It plays no part in stopping a reply[^13].
- **Echo gating.** With `bargeInMinimumWords` at 1 the first word
  interrupts[^1]. `consumeEcho()` runs when a reply finishes or is stopped for
  another reason, never on a barge-in[^14][^9].
- **The fade-in.** Each reply fades in over 200 ms so echo cancellation can
  adapt[^15]. That changes what the microphone hears, not when words arrive.
- **Loading the model.** `analyzer.start` returned at once and
  `prepareToAnalyze` took 0.05 s in the experiment, with the model already
  warm. A cold start was not measured.

### A second way they talk over each other

`speakNextIfIdle()` holds a reply back while `transcript.isEmpty` is
false[^3]. The transcript stays empty until the transcriber's first result, so
for up to about 4 s after Adam starts talking a reply that arrives will start
playing over him. The doc comment on `speak(_:)` promises the opposite ("A
message waits while an utterance is in progress")[^16]. Gating
`speakNextIfIdle()` on voice activity closes that window.

## 2. Measurements

**Method.** A script (appendix B) renders one spoken sentence with
`AVSpeechSynthesizer.write`, builds a timeline of quiet, the sentence, 5 s of
quiet, the sentence again, and feeds it to `SpeechAnalyzer` at real-time pace
in 85 ms chunks, as the tap does. It prints the wall-clock time of every
result. "First word" is the first result containing a word, minus the time
speech starts in the audio.

**Limits.** Clean synthetic speech with a faint synthetic noise floor. **No
echo path, no voice processing, no real microphone, no reply playing.** One
Mac. Two utterances per run, one run per configuration. Treat the numbers as
the recognizer's floor, not as what Adam will see on the phone speaker.

| Transcriber options | First word after speech starts | Results arrive |
|---|---|---|
| The app's: `.volatileResults`, `.alternativeTranscriptions` | 0.93 s, 3.79 s | about every 3.8–3.9 s of audio |
| Same, speech starting 1.2 s later, after `prepareToAnalyze` | 3.63 s, 2.59 s | same |
| The app's, plus a `SpeechDetector` module | 4.84 s, 3.79 s | same |
| The app's, plus `.fastResults` | 0.91 s, 0.89 s | about every 0.9–1.0 s |
| `.fastResults` plus a `SpeechDetector` module | 0.92 s, 0.89 s | same |

Raw output is in appendix A[^17].

Other things the runs showed:

- **`SpeechDetector` reported nothing.** Created with `reportResults: true`
  and added to the analyzer's modules, its `results` sequence never yielded an
  element in either run. It did change the transcriber's behaviour (below), so
  it was running. This may be a mistake in how the script uses it; it is not
  proof the API is broken.
- **Phantom words from the noise floor.** In all three runs without
  `SpeechDetector` whose first block of audio held only the noise floor, the
  transcriber produced a short final result before any speech ("Yeah.",
  "Mhm."), with and without `.fastResults`. The one run with `SpeechDetector`
  in that situation produced none. The noise was synthetic white noise, so
  this may not happen with a real microphone, but it is worth checking.
- **`finalize(through:)` returns words in about 0.1 s but damages them.**
  Called 0.6 s after speech started, it delivered "Wait." 0.1 s later, and the
  next word ("stop") was lost from the final text both times. It is safe only
  where no word is being spoken, for example once the voice has gone quiet.

## 3. Options

"Latency" is from the start of speech to a usable signal. "Own voice" is how
it behaves while the app's speech is playing through the speaker.

### Apple APIs

| Option | Latency | Own voice | Size, license | Effort here | iOS / macOS | Verdict |
|---|---|---|---|---|---|---|
| `SpeechTranscriber` volatile results (today) | 0.9–3.8 s measured[^17] | Relies on echo cancellation | Built in | None | 26+ / 26+ | Too slow |
| `SpeechTranscriber` with `.fastResults` | 0.9 s measured[^17]. Apple: "reduces result latency by using a smaller 'context window'", "faster but also less accurate"[^18] | Same | Built in | One option in `LiveSpeech.makeTranscriber` | 26+ / 26+[^18] | Do it for the transcript; too slow for barge-in |
| `SpeechDetector` module | Not documented[^19]; delivered no results in the experiment[^17] | Unknown | Built in | Small | 26+ / 26+[^19] | Not usable as a signal as tested. It "only functions in conjunction with a SpeechTranscriber or DictationTranscriber"[^19] and exists to gate transcription, to save power[^19] |
| `SpeechAnalyzer.finalize(through:)` | About 0.1 s after the call, measured[^17] | n/a | Built in | Small | 26+ / 26+ | Not for speech onset (it cuts words). Useful later for sending sooner once the voice goes quiet |
| Muted-talker listener, `AVAudioInputNode.setMutedSpeechActivityEventListener` | Not documented | Runs inside voice processing | Built in | Small | 17+ / 14+[^20] | Only fires "while the input is muted" through `voiceProcessingInputMuted`[^20]. A muted input gives the recognizer no audio, so the first words of a barge-in would be lost |
| Core Audio `kAudioDevicePropertyVoiceActivityDetectionEnable` / `...State` | Not documented | "can be used with input audio and has echo cancellation"[^21] | Built in | Medium (HAL property listener) | macOS only[^21] | Mac-only, so not the one approach |
| SoundAnalysis built-in classifier | At least 0.5 s: the smallest window it accepts is 0.5 s (default 3 s)[^22] | No echo handling of its own | Built in; 303 classes, one of them "speech"[^22] | Medium | both | Too slow, and far more model than needed |
| Loudness (RMS) on the echo-cancelled tap, as `VoiceActivityDetector` does | 100–200 ms by estimate: one or two tap buffers of at least 100 ms[^12][^10] | Needs an echo-aware threshold: echo cancellation "typically" gives more than 20 dB once converged[^23], so loud speech can leave an audible remainder | No dependency | Small: already in the tap | both | **Where to start** |

No new voice-activity API appeared in the 27 SDK. What it adds to Speech is
input plumbing and options: `AnalyzerInputConverter`,
`AssetInputSequenceProvider`, `CaptureInputSequenceProvider`, new
`AnalyzerInput` members, `SpeechAnalyzer.Options.ignoresResourceLimits` and a
new error code[^24].

### Third-party detectors

A dagger (†) marks a fact a helper agent read from the linked source and I did
not re-check. Everything else in this section I read at the source myself.

| Option | Frame size | Accuracy | Own voice | Size, license | Verdict |
|---|---|---|---|---|---|
| **Silero VAD** (v6) | 512 samples, 32 ms at 16 kHz[^45]. "less than 1ms" per chunk on one CPU thread[^46] | Its authors' own tables: ROC-AUC 0.97; on a noise-only set it is right 0.87 of the time[^47] | None: it detects any speech, an echo included | "around two megabytes"; MIT[^46][^48] | The detector to move to if loudness misfires |
| WebRTC VAD | 10, 20 or 30 ms†[^54] | In the same tables: ROC-AUC 0.73, and 0 on the noise-only set[^47] | None | Small C code; BSD 3-Clause†[^55] | Little better than loudness. Its Swift wrappers are stale†. Skip |
| TEN VAD | 10 or 16 ms hops†[^56] | ROC-AUC 0.93 in Silero's table[^47] | None | Under 1 MB†[^56]. Apache 2.0 **with added conditions**, the first being "You may not Deploy the ten-vad in a way that competes with Agora's offerings"[^49] | No Swift package†; the licence and packaging rule it out |
| Picovoice Cobra | Not checked | Not checked | None | Commercial; needs an access key†[^57] | Skip |

Ways to run Silero from Swift, none of them a clean drop-in:

| Route | What I found |
|---|---|
| FluidAudio (Swift package, Apache-2.0†[^58]) | Its Silero VAD takes 4096-sample chunks: "256ms at 16kHz"[^50]. Too coarse for a 200 ms target. Models download on first use by default†[^58] |
| SileroVADKit (Swift package, MIT) | CoreML, 512-sample frames, but a two-commit repository with 7 stars[^51]. A reference, not a dependency |
| ONNX Runtime's Swift package (MIT†) with the official `silero_vad.onnx` | The runtime is a binary download of about 52 MB†[^59]; how much it adds to the app is not known |
| sherpa-onnx (Swift package, Apache-2.0†) | Wraps ONNX Runtime; its iOS framework archive is about 16 MB†; documents Silero v4 and v5†[^60] |
| Bundle a CoreML conversion and call CoreML directly | No third-party code. MIT conversions exist†[^61]; whether a 32 ms one works as is was not verified |

### Other streaming recognizers

Parakeet (through FluidAudio), sherpa-onnx's streaming Zipformer, WhisperKit
and Moonshine all run on device from Swift†. The helper found no measured
first-word time for any of them, the Parakeet models are hundreds of megabytes
and carry NVIDIA's own licence†[^62], and none removes the need for a VAD. With
`.fastResults` available, replacing Apple's recognizer isn't worth it for this
problem.

### How voice-agent frameworks handle barge-in

- **LiveKit Agents interrupts, then takes it back if it was false.** By
  default speech must last 0.5 s to count ("Minimum speech length (s) to
  register as an interruption"), silence after an interruption makes it false
  after 2.0 s, and `resume_false_interruption` is on: "Resume the agent's
  speech after a false interruption."[^52] Its docs say it pauses the speech
  on user speech, and it uses Silero VAD†[^63].
- **Pipecat stops outright:** "the bot stops immediately, in-flight work is
  cancelled", and audio not yet played is discarded[^53]. Its VAD waits 0.2 s
  before confirming speech by default†[^64].

Both wait 0.2 to 0.5 s of speech before interrupting. Adam's target (under
0.2 s) is more eager than either default, so false triggers will be more
common and the resume stage matters more.

## 4. Recommendation

### The approach: pause on voice, stop on words

Barge-in becomes two stages, driven by a VAD on the echo-cancelled microphone
tap.

1. **Voice heard while a reply plays (tentative).** Within one or two tap
   buffers of the voice starting, fade the reply out over 30 to 50 ms and
   pause the player. The queue and the rest of the reply are kept.
2. **Confirmed.** The transcriber reports a word, or the voice has continued
   for about half a second: do what `silence(consumingEcho: false, reason:
   "bargeIn")` does today[^9]. The reply and the queue are dropped and the
   utterance continues as the next message.
3. **Not confirmed.** The voice stops and no word follows within about 1.5 s:
   resume the reply with a short fade-in.

The first stage is what makes it feel immediate. The second and third keep a
cough, a door or the bot's own echo from costing a whole reply: a false
trigger is a short gap, not a lost answer.

Turn `.fastResults` on as part of this, so the confirmation arrives in about a
second instead of up to four, and so the live transcript keeps up.

**Expected timing (not measured):** up to one tap buffer of waiting (100 ms at
the documented minimum[^12]), plus 60 to 120 ms of voiced frames to be sure, so
the fade starts 100 to 220 ms after the voice does, and the speaker is quiet
about 50 to 100 ms after that. Getting reliably under 200 ms needs smaller
buffers than a tap allows (see step 8). All the times in this section are
starting values to tune on a device.

LiveKit Agents does much the same by default: when an interruption is
followed by 2.0 s of silence, it resumes the agent's speech[^52].

### The detector

**Start with the loudness detector already in the tap**, reworked to judge
short frames and made echo-aware (below). It needs no dependency and the
offline test bed can already drive it.

**Move to Silero VAD if device logs show false pauses from noise.** A speech
model ignores key clicks, bumps and other noise that a loudness detector takes
for a voice; the app has already needed one fix of that kind[^25]. Silero is
MIT, about 2 MB, and works in 32 ms frames[^45][^46][^48], but there is no
ready Swift package that fits (section 3), so it is real work. Both detectors
sit behind one seam, so the change is contained.

Neither detector can tell the bot's voice from Adam's: an echo that gets
through *is* speech. The level check and the pause test below are what handle
that, not the choice of detector.

### Fade out or hard stop

- **Tentative stage: fade, then pause.** A 30 to 50 ms fade avoids a click and
  is short enough to feel instant. Pause rather than duck: pausing removes the
  echo, so the recognizer hears Adam cleanly, and it enables the echo test
  below. `pause()` keeps what is scheduled ("The player's sample time does not
  advance while the node is paused"), where `stop()` clears it[^26].
- **Confirmed stage: stop**, as today.
- **Resume: fade in.** Reuse the existing 200 ms fade-in[^15].

### Keeping the bot's own voice from triggering it

In order of importance:

1. **Keep what exists:** voice processing on the input node, and the 200 ms
   fade-in at the start of each reply[^15].
2. **Raise the bar while speaking.** While a reply plays, require the
   microphone level to exceed the echo that normally gets through, plus a
   margin, and a longer run of voiced frames than when idle. The app already
   logs the loudest post-cancellation microphone level for each reply
   (`micPeakDb` in "reply ended")[^27]; replies that finished uninterrupted in
   a quiet room give the starting number.
3. **Ignore the first 250 ms of each reply.** Apple says convergence "should
   complete within approximately 200ms"[^23].
4. **The pause is itself a test.** If the "voice" disappears within about
   150 ms of pausing the player, it was the reply's own echo: resume at once
   and raise the bar for the rest of that reply. A real voice keeps going.
5. **No echo cancellation, no VAD barge-in.** The half-duplex fallback stays
   as it is[^1].

### Where it plugs in

| Change | Where |
|---|---|
| Frame-based detection and voice started/ended events, in place of the single "heard voice" flag | `VoiceActivity.process` and `VoiceActivityDetector`[^10], called from `Pipeline.microphoneTap`[^5] |
| A seam for the detector, so tests can script it | `VoiceEnvironment`[^28] |
| A task that reads the events on the main actor | `pipeline.tasks` in `VoiceLoop.startPipeline`[^6] |
| The two-stage decision as a pure type with injected times, like `PauseDetector` | new file in `Sources/VoiceLoop/` |
| Pause, resume, fade | `VoiceLoop.silence` and `Pipeline.player`[^9] |
| Confirmation by words | the existing barge-in branch of `VoiceLoop.handle`[^1] |
| Hold a new reply while voice is active | `VoiceLoop.speakNextIfIdle`[^3] |
| `.fastResults`, and `prepareToAnalyze` | `LiveSpeech.makeTranscriber` and `LiveRecognizer.start`[^2] |

### Fallback

The main risk is the one `PLAN.md` already names: on the built-in speaker,
echo cancellation may not remove enough of the reply[^65]. If the bot's own
voice keeps pausing it there, whatever the detector:

- **On the speaker:** keep word-based barge-in, with `.fastResults`. That is
  today's design with one option changed, and about 1 s instead of up to 4.
- **On headphones and AirPods:** keep the VAD barge-in. There is no echo path
  there[^65].

Step 2 of the plan delivers the speaker half of this on its own, so it is
worth doing first whatever happens to the rest.

### Test plan on the offline test bed

The pretend microphone can already "talk": `OfflineAudio.isVoicePresent`
plays tone bursts loud enough for the loudness detector[^29], and
`ScriptedRecognizer.hear` supplies words[^30].

New tests, driving the real `VoiceLoop`:

1. **Voice pauses a reply before any word.** Speak a long reply, set
   `isVoicePresent`, and expect `playedFrames` to stop growing with no
   `hear(...)` call.
2. **Words then confirm.** After the pause, `hear("Wait.")`: the reply and the
   queue are gone, as `talkingOverAReplyStopsItAndBecomesTheNextUtterance`
   checks today[^31].
3. **A short noise resumes.** Voice on and off again, no words: the reply
   finishes, and the frames played match the reply played alone.
4. **Sustained voice with no words confirms** after the hold time.
5. **A reply doesn't start while voice is present.** `isVoicePresent`, then
   `speak("Hi.")`: nothing plays until the voice stops.
6. **Half-duplex is unchanged.** With `hasVoiceProcessing = false`, voice
   never pauses a reply[^32].
7. **The bot's echo doesn't trigger.** This needs one addition to
   `OfflineAudio`: an echo path that mixes a delayed, attenuated copy of the
   rendered output into the pretend microphone. Today the microphone never
   hears the speaker[^29]. With a small leak the reply plays through; with a
   large one the pause test (point 4 under "Keeping the bot's own voice from
   triggering it") resumes it.
8. **Pure unit tests** for the detector (level sequences in, events out) and
   for the two-stage decision (injected times), like the existing
   `PauseDetector` tests.

Two things to design for:

- **Count time in audio frames, not wall-clock time.** The offline engines
  render far faster than real time[^29], so a window measured on the wall
  clock would be flaky in tests.
- **Silero is unlikely to hear a 440 Hz tone as speech** (not tested). Loop
  tests should use a scripted detector through the `VoiceEnvironment` seam, and
  the real model gets its own test fed with speech rendered by
  `AVSpeechSynthesizer`.

Not testable offline: how much echo really gets through, real timing on the
speaker, AirPods. Those need the device runs listed in section 6.

### Implementation steps

Each is small enough to review alone.

1. **Timeline logging** (section 5). Run it once on the phone and the Mac for
   a baseline.
2. **`.fastResults`** and `prepareToAnalyze`. Check accuracy and phantom words
   with a real microphone; if phantom words appear, try adding
   `SpeechDetector` as a module.
3. **Hold replies while voice is active** in `speakNextIfIdle`.
4. **Voice started/ended events** from the tap, with the loudness detector
   reworked to judge 20 ms frames inside each buffer. Pure, unit-tested.
5. **The two-stage decision** as a pure type, then pause, resume and fade in
   the loop. Tests 1 to 6.
6. **Echo-aware threshold, the 250 ms hold-off, and the pause test.** Add the
   echo path to `OfflineAudio`. Test 7.
7. **Tune on devices** from the logs: false pauses per minute of speech, and
   onset-to-pause time. Decide whether Silero is needed.
8. **Silero** behind the detector seam, if step 7 says so. Separately, if
   100 ms tap buffers are the limit, try an `AVAudioSinkNode` for smaller
   ones (not verified to work alongside voice processing or offline).

Out of scope here but cheap once the VAD exists: call
`finalize(through:)` when the voice goes quiet, so a finished sentence is sent
without waiting for the next block of results.

## 5. Logging

### What is logged today

Everything in `VoiceLoop` logs under the label `voice.loop`[^33]. The log file
keeps `.info` and above[^34]. Each line carries a wall-clock UTC timestamp to
the millisecond, the thread, the level, the source function and line, the
label, a category, the message and the metadata[^35].

| Event | Message | Where |
|---|---|---|
| Listening starts | "voice mode started" with the audio formats and `echoCancellation` | `VoiceLoop.startPipeline`[^6] |
| Listening stops | "voice mode stopped" | `VoiceLoop.tearDown`[^36] |
| Echo cancellation can't start | "voice processing failed to start; trying without echo cancellation" | `VoiceLoop.makeRunningPipeline`[^37] |
| Engine stops or restarts | "audio engine stopped", "audio engine restarted", and two failure messages | `VoiceLoop.engineStopped`[^38] |
| Barge-in | "speech interrupted a reply" with `words` | `VoiceLoop.handle`[^1] |
| A reply ends | "reply ended" with `reason`, `ms`, `ignoredResults`, `micPeakDb`, `echoCancellation` | `VoiceLoop.logReplyEnded`[^27] |
| Failures | transcriber, rebuild, resume, model install | several |

### What is missing

- **Microphone buffers:** nothing. Not the first buffer, not the real tap
  size, not when audio first reaches the recognizer. The tap ignores the
  buffer's capture time (`{ buffer, _ in`)[^5].
- **Recognizer results:** nothing, partial or final. This is the gap that
  hides the 4 to 5 s: no line says when a result arrived or how old its audio
  was.
- **Voice activity:** nothing. The detector sets a flag that is polled every
  100 ms[^11]; when the voice started is never recorded.
- **Speech starting:** nothing when a reply starts, or when its first audio is
  scheduled[^3].
- **Speech stopping:** "reply ended" is written before the player is
  stopped[^9], and carries a duration, not the moment the stop finished.
- **The barge-in decision** has no timing: not how long since the voice
  started, nor how long the stop took.
- **Utterances:** nothing when one is sent or discarded[^11].
- **Timestamps** are wall-clock, written when the log call runs. They are not
  monotonic, and nothing ties a line to the audio timeline. Two debug-level
  messages never reach the file[^34].

### What was added

Built after this research, as step 1 of the implementation steps, and
described here as built. The differences from the first draft of this section
are listed after the table.

One label, `voice.timeline`, at `.info`, so `grep label=voice.timeline` gives
the whole story. (FellerBuncher's own `category=` field is set by a parameter
on its logging calls[^39], which `VoiceLoop` can't use: only `WinstonLogging`
may import FellerBuncher[^40]. The label is the repo's unit of filtering.)
`VoiceTimeline` writes every line; there is one per listening session, owned by
its `Pipeline`.

**Every line carries:**

| Key | Meaning |
|---|---|
| `tMs` | Monotonic milliseconds since this listening session started, from the host clock (`mach_absolute_time`, the same clock as `AVAudioTime.hostTime`). The session starts when its pipeline is built, just before the engine starts. For what the microphone tap or the synthesizer recorded, it is when that happened (a buffer's *capture* time), not when the line was written. A buffer with no capture time (an offline engine in the tests) uses the time the tap was called |
| `audioMs` | Position on the analyzer's timeline (`FedAudioClock.time`)[^41], on the lines about audio: 3 to 9, 15 and 16. For a microphone buffer it is where the buffer starts |
| `session` | `runID`, so lines from a rebuilt engine can be told apart |

Messages are fixed strings and keys are lowerCamelCase, as the README
requires; counts, levels and times only, never text[^40].

**Nothing logs from the audio thread or the synthesizer's thread.**
`Pipeline.microphoneTap` hands each buffer's capture time, analyzer position
and `VoiceActivity.process` reading to `MicrophoneTimeline`, which only records
them under a `Mutex`; `SpeechPlayback` records when its first buffer is
scheduled. `VoiceTimeline.writeRecorded()` writes those lines on the main
actor: `VoiceLoop.checkForPause` calls it every 100 ms, and every other line
calls it first, so the file stays in order.

| # | Message | Where it is written | Extra keys |
|---|---|---|---|
| 1 | "timeline started" | `VoiceLoop.startPipeline`, after "voice mode started"[^6] | `echoCancellation`, `fastResults`, `tapFramesRequested`, `analyzerRate`. Its `tMs` is 0 |
| 2 | "recognizer started" | `VoiceLoop.startPipeline`, after line 1[^6] | `startMs` (how long `recognizer.start(inputs:)` took) |
| 3 | "first mic buffer" | recorded in `Pipeline.microphoneTap`[^5]; written by `writeRecorded()`. Again after the engine restarts | `tapFrames`, `tapRate`, `deliveryMs` (callback time minus capture time; left out when the buffer has no capture time) |
| 4 | "voice started" | recorded in `Pipeline.microphoneTap` from `VoiceActivity.process`[^10]; written by `writeRecorded()` | `levelDb`, `floorDb`, `speaking`, `detectMs` (capture to the line) |
| 5 | "voice ended" | same | `voicedMs` |
| 6 | "first result" | `VoiceLoop.handle`, when a result gives an empty transcript its first word[^1] | `rangeStartMs`, `rangeEndMs`, `wordStartMs`, `lagMs` (`audioMs` minus `wordStartMs`), `words`, `final`, `speaking`, `sinceVoiceMs` |
| 7 | "result" | `VoiceLoop.handle`, every other result applied[^1] | `rangeEndMs`, `words`, `final` |
| 8 | "result ignored" | `VoiceLoop.handle`, the branch that ignores results while speaking[^1] | `reason` (`noEchoCancellation` or `tooFewWords`), `words` |
| 9 | "barge-in decided" | `VoiceLoop.handle`, the barge-in branch[^1] | `trigger` (`words`; later also `voice`), `words`, `sinceVoiceMs`, `replyMs` |
| 10 | "speech stop requested" | `VoiceLoop.silence`, once it has a reply to stop[^9] | `reason`, `reply` |
| 11 | "speech stopped" | `VoiceLoop.silence`, after `player.stop()` returns[^9] | `reply`, `stopMs`, `outputLatencyMs` |
| 12 | "speech started" | `VoiceLoop.speakNextIfIdle`, after `player.play()`[^3] | `reply` (counts replies in the session), `chars`, `queued`, `voiceActive` |
| 13 | "speech first audio" | recorded in `SpeechPlayback` when the first buffer is scheduled[^42]; written by `writeRecorded()` | `reply`, `synthMs` |
| 14 | "speech finished" | `VoiceLoop.speechFinished`[^43] | the "reply ended" fields, and `reply` |
| 15 | "utterance sent" | `VoiceLoop.checkForPause`, where it yields[^11] | `words`, `sinceVoiceMs`, `sinceChangeMs`, `endsSentence` |
| 16 | "utterance discarded" | `VoiceLoop.discardCurrentUtterance`[^44] | `words` |
| 17 | "barge-in timeline" | `VoiceLoop.silence`, after line 11, when a barge-in stopped the reply[^9] | `voiceToResultMs`, `resultToStopMs`, `voiceToStopMs` |

What the keys measure:

- "voice started" is the first buffer the existing detector calls voice after
  quiet. `speaking` is whether a reply was playing when the line was written,
  up to 100 ms after the buffer.
- "voice ended" is written once the voice has been absent for 0.5 s of audio
  (counted in frames, so the gaps between words don't end it). Its `tMs` and
  `audioMs` are where that quiet began, so the voice stopped at `tMs` and the
  line could only be written about 500 ms later. `voicedMs` is the span's
  length on the analyzer's timeline.
- `sinceVoiceMs` on lines 6 and 9, and the `voiceTo...` keys on line 17, count
  from the latest "voice started". If the speaker paused for more than 0.5 s
  before the words that were recognized, that is a later start than the one
  that began the utterance; the "voice started" lines above show it.
- `sinceVoiceMs` and `sinceChangeMs` on line 15 are the pause detector's own
  view: since its 100 ms poll last heard voice, and since the transcript last
  changed.
- `wordStartMs` is where the result's first kept word starts, from the
  word's `audioTimeRange`; it and `lagMs` are left out if the result has no
  word timings.
- `replyMs` is how long the reply had been playing; `synthMs` is from just
  before `synthesizer.write` to the first buffer scheduled on the player;
  `stopMs` is from line 10 to line 11.
- `resultToStopMs` is from the barge-in decision (when the result was
  handled) to the player having stopped.

`outputLatencyMs` is `engine.outputNode.presentationLatency`, the hardware
latency the system reports on both platforms[^20], so "the speaker went quiet"
is about `tMs + outputLatencyMs`. Measuring the real moment would need a tap
on the output, which isn't worth it for diagnosis.

"first mic buffer" is also when audio first reaches the recognizer: the same
tap callback converts the buffer and queues it[^5].

**Differences from the first draft of this section:**

- "timeline started" has `tMs=0`, the session's start, though it is written
  after the engine and the recognizer have started, beside "voice mode
  started". Line 2 follows it.
- "first mic buffer" is written again after the engine restarts, since the tap
  is installed again and its size and rate can change with the hardware. On
  the iPhone every new engine stops once right after starting, so the second
  line is the one that describes the running tap.
- `deliveryMs` is left out when the buffer has no capture time, rather than
  showing 0.
- "first result" has `wordStartMs`, and `lagMs` is measured from it, not from
  `rangeStartMs`: a result's range can start seconds before its first word (in
  appendix A, "Wait" spoken at 3.0 s came in a result for 0.000 to 3.910 s).
- "speech stop requested" is written only when there is a reply to stop:
  `silence` is also called on every teardown, when there may be none.
- The speech lines carry `reply`, so the lines for one reply can be matched.
- "barge-in timeline" is written when a barge-in decided the stop, which is
  when `silence` has the reason `bargeIn`.
- "speech finished" repeats the fields "reply ended" computed rather than
  computing them again, because reading the peak level resets it.
- `fastResults` comes from a new `Recognizer.reportsFastResults` property.

**Format.** As the file writes it today[^35], for example:

```
2026-11-13 17:20:01.123 [UI] INFO VoiceTimeline.result(_:words:isFirst:firstWordStart:):279 label=voice.timeline category=default msg="first result" tMs=18342 audioMs=18110 session=3 rangeStartMs=13900 rangeEndMs=18100 wordStartMs=14320 lagMs=3790 words=1 final=false speaking=true sinceVoiceMs=3788
2026-11-13 17:20:01.131 [UI] INFO VoiceTimeline.speechStopped(outputLatency:):351 label=voice.timeline category=default msg="barge-in timeline" tMs=18350 session=3 voiceToResultMs=3788 resultToStopMs=8 voiceToStopMs=3796
```

(The example values are made up. The exact form of the source field and the
`category=default` value are assumed: the formatter writes both fields, but
how it renders them when no category is given was not checked. The source is
the `VoiceTimeline` method that wrote the line.)

**Reading it.** `voiceToResultMs` is the recognizer's delay. `lagMs` on "first
result" says how old the first word's audio was when the result arrived.
`deliveryMs` on "first mic buffer" and `tapFrames` say what the tap really
delivers. "speech started" with `voiceActive=true` is a reply starting over
Adam.

## 6. Not verified, and what needs Adam

**Needs a build and a device, with Adam talking:**

- Real barge-in timing on the phone speaker, AirPods and the Mac. The timeline
  logging (step 1) gives it from one session each.
- How much of a reply gets through echo cancellation (`micPeakDb`), which sets
  the echo threshold. The app's existing logs already hold this; I could not
  read them from my sandbox.
- Whether `.fastResults` costs accuracy or adds phantom words with a real
  microphone.

**Not verified:**

- Whether the 3.8 s result cadence is the same on an iPhone.
- The real tap buffer size with voice processing on.
- Why `SpeechDetector` delivered no results.
- Whether voice processing dulls the near-end voice during a reply.
- Whether `AVAudioSinkNode` works beside the voice-processing input and in
  offline rendering, and how smoothly `player.volume` ramps.
- The latency of Apple's muted-talker listener and of the macOS HAL
  voice-activity property: neither is documented.

**Tooling notes:** the Apple documentation tool was blocked by the sandbox's
path check, so Apple pages were read through the sosumi.ai mirror of the same
content. `say` and `swiftc` were not allowed; the script ran with `swift` and
rendered its own speech.

## Appendix A: raw measurement output

One run per configuration. `T` lines are transcriber results: `wall` is
seconds since feeding began, `range` is the audio the result covers, `final`
is 1 for a final result. Only the first result of each burst is shown; bursts
arrive within a few milliseconds.

**The app's options** (speech starts at 3.010 and 11.704):

```
T wall=3.939 range=0.000-3.910 final=0 words=1 text="Wait"
T wall=7.833 range=0.000-7.820 final=0 words=1 text="Wait,"
T wall=7.845 range=3.000-3.900 final=1 words=1 text="Wait,"
T wall=15.492 range=6.720-15.470 final=0 words=1 text=" Wait"
T wall=15.518 range=11.580-12.180 final=1 words=1 text=" Wait,"
```

**The app's options, after `prepareToAnalyze` (0.052 s)** (speech starts at
4.210 and 12.904):

```
T wall=3.930 range=0.000-3.910 final=0 words=1 text="."
T wall=3.938 range=0.000-0.900 final=1 words=1 text="Mhm."
T wall=7.843 range=0.900-7.820 final=0 words=1 text=" Wait"
T wall=11.662 range=5.460-11.645 final=0 words=7 text=" Tell me about the weather tomorrow instead."
T wall=15.493 range=7.860-15.470 final=0 words=1 text=" Wait"
T wall=19.312 range=14.040-19.295 final=0 words=6 text=" Tell me about the weather tomorrow"
```

**The app's options plus `SpeechDetector`** (speech starts at 3.010 and
11.704; no detector results were printed):

```
T wall=7.854 range=0.000-7.820 final=0 words=1 text="Wait"
T wall=11.666 range=4.290-11.645 final=0 words=7 text=" Tell me about the weather tomorrow instead"
T wall=15.493 range=6.810-15.470 final=0 words=1 text=" Wait"
T wall=19.309 range=12.930-19.295 final=0 words=7 text=" Tell me about the weather tomorrow instead"
```

**With `.fastResults`** (speech starts at 3.010 and 11.704):

```
T wall=2.049 range=0.000-2.040 final=0 words=1 text="."
T wall=2.993 range=0.000-2.975 final=0 words=1 text=".."
T wall=3.002 range=0.000-2.880 final=1 words=1 text="Yeah."
T wall=3.920 range=2.880-3.910 final=0 words=1 text=" Wait"
T wall=4.938 range=2.880-4.930 final=0 words=2 text=" Wait, stop"
T wall=5.882 range=4.320-5.865 final=0 words=3 text=" Tell me about"
T wall=6.811 range=4.320-6.800 final=0 words=6 text=" Tell me about the weather tomorrow"
T wall=7.834 range=4.320-7.820 final=0 words=7 text=" Tell me about the weather tomorrow instead."
T wall=12.591 range=6.900-12.580 final=0 words=1 text=" Wait"
T wall=13.526 range=6.900-13.515 final=0 words=1 text=" Wait,"
T wall=14.549 range=12.960-14.535 final=0 words=3 text=" Tell me about"
```

**With `.fastResults` plus `SpeechDetector`** (speech starts at 3.010 and
11.704; no detector results were printed):

```
T wall=3.930 range=0.000-3.910 final=0 words=1 text="Wait"
T wall=4.945 range=0.000-4.930 final=0 words=1 text="Wait,"
T wall=5.878 range=4.320-5.865 final=0 words=3 text=" Tell me about"
T wall=12.596 range=6.900-12.580 final=0 words=1 text=" Wait"
T wall=13.527 range=6.900-13.515 final=0 words=1 text=" Wait,"
```

**The app's options, calling `finalize(through:)` 0.6 s after speech starts**
(speech starts at 4.210 and 12.904; `F` is the call):

```
T wall=3.935 range=0.000-3.910 final=0 words=1 text="."
T wall=3.970 range=0.000-0.900 final=1 words=1 text="Mhm."
T wall=4.942 range=0.900-4.930 final=0 words=1 text=" Wait"
T wall=4.955 range=4.080-4.930 final=1 words=1 text=" Wait."
F finalize(through: 4.845) called=4.850 returned=4.955
T wall=8.869 range=4.930-8.840 final=0 words=1 text="Stop"
T wall=8.934 range=4.930-5.470 final=1 words=1 text="..."
T wall=8.934 range=5.470-6.490 final=1 words=5 text=" Tell me about the weather"
T wall=13.613 range=7.930-13.600 final=0 words=1 text=" Wait"
F finalize(through: 13.515) called=13.516 returned=13.628
T wall=17.569 range=13.600-15.160 final=1 words=6 text=",.., tell me about the weather"
```

**SoundAnalysis built-in classifier**, read from the framework at run time:

```
defaultWindowSeconds=3.0
defaultOverlapFactor=0.5
allowedWindowRange=0.5...15.0000625
classCount=303
speechLabels=["speech"]
```

## Appendix B: the measurement script

Not in the repo. Run with
`swift -swift-version 5 main.swift "<sentence>" base|fast det|nodet prep|noprep [lead seconds] [finalize after seconds]`.
It needs the en-US speech model installed for the process that runs it.

<details>
<summary>main.swift</summary>

```swift
import AVFoundation
import CoreMedia
import Foundation
import Speech

func out(_ s: String) {
    print(s)
    fflush(stdout)
}

func f3(_ x: Double) -> String { String(format: "%.3f", x) }

final class Box: @unchecked Sendable {
    var t0 = ContinuousClock.now
    func elapsed() -> Double {
        let d = t0.duration(to: .now)
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

/// Renders text to samples with AVSpeechSynthesizer.write, converting each buffer as it arrives.
final class Synth: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let target: AVAudioFormat
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var continuation: CheckedContinuation<Void, Never>?

    init(target: AVAudioFormat) {
        self.target = target
    }

    func render(_ text: String) async -> [Float] {
        synthesizer.delegate = self
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            continuation = c
            lock.unlock()
            synthesizer.write(utterance) { [self] buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
                lock.lock()
                defer { lock.unlock() }
                if converter?.inputFormat != pcm.format {
                    converter = AVAudioConverter(from: pcm.format, to: target)
                    converter?.primeMethod = .none
                }
                guard let converter else { return }
                let ratio = target.sampleRate / pcm.format.sampleRate
                let capacity = AVAudioFrameCount((Double(pcm.frameLength) * ratio).rounded(.up)) + 16
                guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
                var supplied = false
                var error: NSError?
                converter.convert(to: output, error: &error) { _, inputStatus in
                    if supplied {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    supplied = true
                    inputStatus.pointee = .haveData
                    return pcm
                }
                if let channel = output.floatChannelData?[0] {
                    samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
                }
            }
        }
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}

let args = CommandLine.arguments
guard args.count >= 5 else {
    out("usage: latency <text to speak> base|fast det|nodet prep|noprep")
    exit(1)
}
let spokenText = args[1]
let useFast = args[2] == "fast"
let useDetector = args[3] == "det"
let usePrepare = args[4] == "prep"

guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
    out("no supported locale")
    exit(2)
}
var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults, .alternativeTranscriptions]
if useFast { reporting.insert(.fastResults) }
let transcriber = SpeechTranscriber(
    locale: locale,
    transcriptionOptions: [],
    reportingOptions: reporting,
    attributeOptions: [.audioTimeRange]
)
let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true)
var modules: [any SpeechModule] = [transcriber]
if useDetector { modules.append(detector) }

let status = await AssetInventory.status(forModules: modules)
out("assetStatus=\(status)")
if status != .installed {
    if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
        try await request.downloadAndInstall()
    }
    out("assetStatusAfter=\(await AssetInventory.status(forModules: modules))")
}
guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
    out("no analyzer format")
    exit(4)
}
out("analyzerFormat=\(format)")
let rate = format.sampleRate

// Render the spoken clip in-process (nothing is played), as mono float at the analyzer's rate.
let monoFloat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
let synth = Synth(target: monoFloat)
let speech = await synth.render(spokenText)
out("clipSeconds=\(f3(Double(speech.count) / rate))")

// Where speech starts and ends inside the clip: 10 ms windows above -40 dBFS.
let win = Int(rate * 0.01)
var onset = -1
var lastLoud = 0
var idx = 0
while idx + win <= speech.count {
    var sum: Float = 0
    for j in idx..<(idx + win) { sum += speech[j] * speech[j] }
    if (sum / Float(win)).squareRoot() > 0.01 {
        if onset < 0 { onset = idx }
        lastLoud = idx + win
    }
    idx += win
}
guard onset >= 0 else {
    out("clip is silent")
    exit(5)
}

// Timeline: quiet, speech, 5 s quiet, speech, 4 s quiet. A faint noise floor throughout.
let leadSeconds = args.count > 5 ? (Double(args[5]) ?? 3) : 3
let lead = Int(rate * leadSeconds)
let gap = Int(rate * 5)
let tail = Int(rate * 4)
var timeline = [Float](repeating: 0, count: lead + speech.count + gap + speech.count + tail)
for j in 0..<speech.count {
    timeline[lead + j] = speech[j]
    timeline[lead + speech.count + gap + j] = speech[j]
}
var rng = SystemRandomNumberGenerator()
for j in 0..<timeline.count {
    timeline[j] += Float.random(in: -0.0006...0.0006, using: &rng)
}
let onset1 = Double(lead + onset) / rate
let end1 = Double(lead + lastLoud) / rate
let onset2 = Double(lead + speech.count + gap + onset) / rate
let end2 = Double(lead + speech.count + gap + lastLoud) / rate
out("config fast=\(useFast) detector=\(useDetector) prepare=\(usePrepare)")
out("onset1=\(f3(onset1)) end1=\(f3(end1)) onset2=\(f3(onset2)) end2=\(f3(end2)) total=\(f3(Double(timeline.count) / rate))")

let box = Box()
let analyzer = SpeechAnalyzer(modules: modules)

Task {
    do {
        for try await r in transcriber.results {
            let text = String(r.text.characters)
            let words = text.split(separator: " ").count
            out("T wall=\(f3(box.elapsed())) range=\(f3(r.range.start.seconds))-\(f3(r.range.end.seconds)) final=\(r.isFinal ? 1 : 0) words=\(words) text=\"\(text)\"")
        }
    } catch {
        out("transcriber error \(error)")
    }
}
if useDetector {
    Task {
        do {
            for try await r in detector.results {
                out("D wall=\(f3(box.elapsed())) range=\(f3(r.range.start.seconds))-\(f3(r.range.end.seconds)) speech=\(r.speechDetected ? 1 : 0) final=\(r.isFinal ? 1 : 0)")
            }
        } catch {
            out("detector error \(error)")
        }
    }
}

if usePrepare {
    let before = ContinuousClock.now
    try await analyzer.prepareToAnalyze(in: format)
    let d = before.duration(to: .now)
    out("prepareSeconds=\(f3(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18))")
}

let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
try await analyzer.start(inputSequence: stream)

// Feed at real-time pace: a chunk is handed over when its last sample would have been recorded.
let chunk = Int(rate * 0.085)
var pos = 0
let forceAfter: Double? = args.count > 6 ? Double(args[6]) : nil
var forced = [false, false]
box.t0 = .now
while pos < timeline.count {
    let n = min(chunk, timeline.count - pos)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
    buf.frameLength = AVAudioFrameCount(n)
    if let p = buf.int16ChannelData {
        for j in 0..<n { p[0][j] = Int16(max(-1, min(1, timeline[pos + j])) * 32767) }
    } else if let p = buf.floatChannelData {
        for j in 0..<n { p[0][j] = timeline[pos + j] }
    } else {
        out("unsupported analyzer sample format")
        exit(6)
    }
    pos += n
    try await Task.sleep(until: box.t0.advanced(by: .seconds(Double(pos) / rate)), clock: .continuous)
    continuation.yield(AnalyzerInput(buffer: buf))
    // Optional: this long after each utterance starts, ask the analyzer to finalize what it has.
    if let forceAfter {
        let fed = Double(pos) / rate
        for (index, onsetTime) in [onset1, onset2].enumerated() where !forced[index] && fed >= onsetTime + forceAfter {
            forced[index] = true
            let through = CMTime(value: CMTimeValue(pos), timescale: CMTimeScale(rate))
            let calledAt = box.elapsed()
            Task {
                do {
                    try await analyzer.finalize(through: through)
                    out("F finalize(through: \(f3(fed))) called=\(f3(calledAt)) returned=\(f3(box.elapsed()))")
                } catch {
                    out("finalize error \(error)")
                }
            }
        }
    }
}
out("fedAll wall=\(f3(box.elapsed()))")
continuation.finish()
try await analyzer.finalizeAndFinishThroughEndOfInput()
try await Task.sleep(for: .seconds(1))
out("done wall=\(f3(box.elapsed()))")
```

</details>

[^1]: [VoiceLoop.handle, the barge-in branch](../../Sources/VoiceLoop/VoiceLoop.swift:VoiceLoop.handle)
[^2]: [LiveSpeech.makeTranscriber, the transcriber's options](../../Sources/VoiceLoop/LiveVoiceEnvironment.swift:LiveSpeech.makeTranscriber)
[^3]: [VoiceLoop.speakNextIfIdle](../../Sources/VoiceLoop/VoiceLoop.swift:VoiceLoop.speakNextIfIdle)
[^4]: [Pipeline.installMicrophoneTap](../../Sources/VoiceLoop/AudioPipeline.swift:Pipeline.installMicrophoneTap)
[^5]: [Pipeline.microphoneTap](../../Sources/VoiceLoop/AudioPipeline.swift:Pipeline.microphoneTap)
[^6]: [VoiceLoop.startPipeline, and LiveRecognizer.start in LiveVoiceEnvironment.swift](../../Sources/VoiceLoop/VoiceLoop.swift:VoiceLoop.startPipeline)
[^7]: [VoiceLoop.listen](../../Sources/VoiceLoop/VoiceLoop.swift:VoiceLoop.listen)
[^8]: [AppModel, which sets pauseThreshold, voice, rate and pausesOtherAudio on the loop but not bargeInMinimumWords](../../Sources/WinstonCore/AppModel.swift:AppModel)
[^9]: [VoiceLoop.silence](../../Sources/VoiceLoop/VoiceLoop.swift:VoiceLoop.silence)
[^10]: [VoiceActivityDetector and VoiceActivity](../../Sources/VoiceLoop/VoiceActivity.swift:VoiceActivityDetector.process)
[^11]: [VoiceLoop.checkForPause, run every 100 ms by a task in startPipeline](../../Sources/VoiceLoop/VoiceLoop.swift:VoiceLoop.checkForPause)
[^12]: [AVAudioNode.h in the macOS 27.2 SDK, installTapOnBus:bufferSize:format:block:, "Supported range is [100, 400] ms."](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.2.sdk/System/Library/Frameworks/AVFAudio.framework/Headers/AVAudioNode.h:81-86)
[^13]: [PauseDetector](../../Sources/VoiceLoop/PauseDetector.swift:PauseDetector.isComplete)
[^14]: [VoiceLoop.consumeEcho](../../Sources/VoiceLoop/VoiceLoop.swift:VoiceLoop.consumeEcho)
[^15]: [SpeechPlayback.fadeIn](../../Sources/VoiceLoop/AudioPipeline.swift:SpeechPlayback.fadeIn)
[^16]: [VoiceLoop.speak, doc comment](../../Sources/VoiceLoop/VoiceLoop.swift:VoiceLoop.speak)
[^17]: [Appendix A of this document: raw output of the measurement script, 2026-11-13](#appendix-a-raw-measurement-output)
[^18]: [Apple, SpeechTranscriber.ReportingOption.fastResults](https://developer.apple.com/documentation/speech/speechtranscriber/reportingoption/fastresults)
[^19]: [Apple, SpeechDetector](https://developer.apple.com/documentation/speech/speechdetector)
[^20]: [AVAudioIONode.h in the macOS 27.2 SDK: presentationLatency (lines 112-123) and setMutedSpeechActivityEventListener (lines 245-257)](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.2.sdk/System/Library/Frameworks/AVFAudio.framework/Headers/AVAudioIONode.h:112-257)
[^21]: [AudioHardware.h in the macOS 27.2 SDK, kAudioDevicePropertyVoiceActivityDetectionEnable](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.2.sdk/System/Library/Frameworks/CoreAudio.framework/Headers/AudioHardware.h:995-1005)
[^22]: [Appendix A of this document: values read from SNClassifySoundRequest(classifierIdentifier: .version1) at run time](#appendix-a-raw-measurement-output)
[^23]: [Apple engineer, Apple Developer Forums, "Acoustic Echo Cancellation does not work initially"](https://developer.apple.com/forums/thread/829784)
[^24]: [Speech.swiftinterface in the macOS 27.2 SDK, declarations marked @available(anyAppleOS 27, *)](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.2.sdk/System/Library/Frameworks/Speech.framework/Versions/A/Modules/Speech.swiftmodule/arm64e-apple-macos.swiftinterface)
[^25]: [VoiceActivityDetector.minimumRun, "so a keyboard click doesn't count"](../../Sources/VoiceLoop/VoiceActivity.swift:VoiceActivityDetector.minimumRun)
[^26]: [AVAudioPlayerNode.h in the macOS 27.2 SDK, stop and pause](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.2.sdk/System/Library/Frameworks/AVFAudio.framework/Headers/AVAudioPlayerNode.h:286-394)
[^27]: [VoiceLoop.logReplyEnded](../../Sources/VoiceLoop/VoiceLoop.swift:VoiceLoop.logReplyEnded)
[^28]: [VoiceEnvironment](../../Sources/VoiceLoop/VoiceEnvironment.swift:VoiceEnvironment)
[^29]: [OfflineAudio and its Microphone](../../Tests/VoiceLoopTestSupport/OfflineAudio.swift:OfflineAudio)
[^30]: [ScriptedRecognizer.hear](../../Tests/VoiceLoopTestSupport/ScriptedRecognizer.swift:ScriptedRecognizer.hear)
[^31]: [BargeInTests.talkingOverAReplyStopsItAndBecomesTheNextUtterance](../../Tests/VoiceLoopTests/VoiceLoopSessionTests.swift:BargeInTests.talkingOverAReplyStopsItAndBecomesTheNextUtterance)
[^32]: [BargeInTests.withoutEchoCancellationTalkingOverAReplyDoesNotInterruptIt](../../Tests/VoiceLoopTests/VoiceLoopSessionTests.swift:BargeInTests.withoutEchoCancellationTalkingOverAReplyDoesNotInterruptIt)
[^33]: [VoiceLoop.log](../../Sources/VoiceLoop/VoiceLoop.swift:VoiceLoop.log)
[^34]: [WinstonLog.bootstrap, "`.info` minimum level, logfmt format, 7-day retention"](../../Sources/WinstonLogging/WinstonLog.swift:WinstonLog.bootstrap)
[^35]: [FellerBuncher, LogfmtFormatter.swift, defaultFields and the timestamp format](https://github.com/adamwulf/FellerBuncher/blob/main/Sources/FellerBuncher/LogfmtFormatter.swift)
[^36]: [VoiceLoop.tearDown](../../Sources/VoiceLoop/VoiceLoop.swift:VoiceLoop.tearDown)
[^37]: [VoiceLoop.makeRunningPipeline](../../Sources/VoiceLoop/VoiceLoop.swift:VoiceLoop.makeRunningPipeline)
[^38]: [VoiceLoop.engineStopped](../../Sources/VoiceLoop/VoiceLoop.swift:VoiceLoop.engineStopped)
[^39]: [FellerBuncher, Logger+Convenience.swift, the category overloads](https://github.com/adamwulf/FellerBuncher/blob/main/Sources/FellerBuncher/Logger+Convenience.swift)
[^40]: [README, Logging conventions](../../README.md:146-185)
[^41]: [FedAudioClock](../../Sources/VoiceLoop/AudioPipeline.swift:FedAudioClock)
[^42]: [SpeechPlayback.receive](../../Sources/VoiceLoop/AudioPipeline.swift:SpeechPlayback.receive)
[^43]: [VoiceLoop.speechFinished](../../Sources/VoiceLoop/VoiceLoop.swift:VoiceLoop.speechFinished)
[^44]: [VoiceLoop.discardCurrentUtterance](../../Sources/VoiceLoop/VoiceLoop.swift:VoiceLoop.discardCurrentUtterance)
[^45]: [Silero VAD, utils_vad.py, "num_samples = 512 if sr == 16000 else 256"](https://github.com/snakers4/silero-vad/blob/master/src/silero_vad/utils_vad.py)
[^46]: [Silero VAD README](https://github.com/snakers4/silero-vad)
[^47]: [Silero VAD wiki, Quality Metrics (the authors' own benchmarks)](https://github.com/snakers4/silero-vad/wiki/Quality-Metrics)
[^48]: [Silero VAD LICENSE, "MIT License"](https://github.com/snakers4/silero-vad/blob/master/LICENSE)
[^49]: [TEN VAD LICENSE](https://github.com/TEN-framework/ten-vad/blob/main/LICENSE)
[^50]: [FluidAudio, VadManager.swift, chunkSize](https://github.com/FluidInference/FluidAudio/blob/main/Sources/FluidAudio/VAD/VadManager.swift)
[^51]: [SileroVADKit repository](https://github.com/polRk/SileroVADKit)
[^52]: [LiveKit Agents, turn.py, interruption options and their defaults](https://github.com/livekit/agents/blob/main/livekit-agents/livekit/agents/voice/turn.py)
[^53]: [Pipecat documentation, Interruptions](https://docs.pipecat.ai/pipecat/fundamentals/interruptions)
[^54]: [py-webrtcvad README, read by a helper](https://github.com/wiseman/py-webrtcvad)
[^55]: [WebRTC LICENSE, read by a helper](https://webrtc.googlesource.com/src/+/refs/heads/main/LICENSE)
[^56]: [TEN VAD README, read by a helper](https://github.com/TEN-framework/ten-vad)
[^57]: [Picovoice Cobra README, read by a helper](https://github.com/Picovoice/cobra)
[^58]: [FluidAudio README and LICENSE, read by a helper](https://github.com/FluidInference/FluidAudio)
[^59]: [ONNX Runtime Swift package and its binary archive's download size, read by a helper](https://github.com/microsoft/onnxruntime-swift-package-manager)
[^60]: [sherpa-onnx repository, release assets and Silero VAD page, read by a helper](https://github.com/k2-fsa/sherpa-onnx)
[^61]: [FluidInference silero-vad-coreml model card, read by a helper](https://huggingface.co/FluidInference/silero-vad-coreml)
[^62]: [FluidInference parakeet-realtime-eou-120m-coreml model card, read by a helper](https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml)
[^63]: [LiveKit Agents docs, Turns and interruptions (and the Silero plugin's vad.py in the livekit/agents repository), read by a helper](https://docs.livekit.io/agents/build/turns/)
[^64]: [Pipecat, vad_analyzer.py, VADParams defaults, read by a helper](https://github.com/pipecat-ai/pipecat/blob/main/src/pipecat/audio/vad/vad_analyzer.py)
[^65]: [PLAN.md, Barge-in behaviour and Risk 1](../../PLAN.md:247-327)
