# Echo cancellation stopped working in builds 41 and 43

Status: findings, 2026-11-16; the echo matching tried for them was removed on
2026-11-17 (see the end). From the iPhone's own logs (iPhone 16e, iOS 27.3,
built-in microphone and speaker), copied off the phone with `xcrun devicectl
device copy from ... --domain-type appDataContainer` (`Library/Logs/Winston`).
Times below are the logs' UTC.

## What the logs show

Every voice session on every build had echo cancellation on and set up as
intended: `voiceProcessing=true`, `sessionMode=AVAudioSessionModeVoiceChat`,
microphone, tap and output all 48 kHz mono, route `MicrophoneBuiltIn+Speaker`.
Speech and cues play through the same engine as the microphone. The audio
session, voice processing, routing and sample rates did not regress.

What changed is how replies end. Replies by build, on every route:

| Build | Played to the end | Cut off by "barge-in" |
|---|---|---|
| 20 | 42 | 0 |
| 22 | 19 | 0 |
| 36 | 19 | 2: a session's first reply, and one at -13 dB (likely real) |
| 38 | 20 | 4: a session's first reply, and three in the car at -12 to -19 dB (likely real) |
| 41 | 0 | 2 |
| 43 | 1 | 4 |

In builds 41 and 43 each cut-off reply was stopped 2.0 to 2.8 s after it
started: about 1 s for Kokoro to render the first sentence, then about 1 s for
the recognizer to report the reply's own first one or two words, whose audio
starts right at the reply's first sound. The microphone peaked at -10 to
-27 dBFS during those replies. In build 36, replies that played to the end on
the speaker mostly peaked between -50 and -60 dBFS.

## The cause: the working sound

The one audio change between build 38 and build 41 is the working sound
(`7ac07c7`, `8ffffa1`), replaced in build 43 by the `agentWorking` cue
(`fbb074c`). The microphone gate added for push-to-talk keeps every frame when
push-to-talk is off. In build 43 the engine's graph is the same as build 38's.

Every reply cut off in builds 41 and 43 followed the working sound:

| Build, time | Before the reply | Reply |
|---|---|---|
| 41, 11-16 18:07:06 | working sound looped until 30 ms before | cut off at 2.5 s, peak -10 dB |
| 41, 11-17 02:13:08 | working sound looped until 0.45 s before | cut off at 2.4 s, peak -21 dB |
| 43, 11-17 04:27:27 | working cue 3.4 s before | cut off at 2.2 s, peak -19 dB |
| 43, 11-17 04:28:03 | working cue 4.4 s before | cut off at 2.8 s, peak -27 dB |
| 43, 11-17 04:28:15 | working cue 2.7 and 5.1 s before | cut off at 2.4 s, peak -26 dB |
| 43, 11-17 04:29:58 | working cue 2.1 s before | cut off at 2.0 s, peak -24 dB |
| 43, 11-17 04:28:20 | **no cue** (followed the reply above, 3 s after) | **played 21.9 s to the end, peak -44 dB** |

Before the working sound, a reply after a long quiet gap played fine: in
builds 20 to 38, replies 20 s to 6 min after the last one played to the end.
So the canceller keeps what it has learned through silence, and the working
sound is what spoils it.

Why the canceller is thrown off isn't documented. Both versions of the sound
are quiet and tonal: build 41's ticks near 2 kHz at a level of about 0.04,
build 43's taps near 320 Hz at about 0.02. An adaptive filter given a weak,
narrowband reference adapts in only those bands and against a poor
signal-to-noise ratio. A canceller that estimates the echo delay from the
reference can lock onto the wrong lag of a periodic tone. Either would leave
the filter wrong for the next reply. Apple's engineer describes about 200 ms
of convergence on new playback ([thread 829784][apple]). On the phone's
speaker the leak lasts long enough for the recognizer to hear a word.

## A second, older leak: the first reply of a session

Builds 36 and 38 cut off the first reply of two speaker sessions (11-15
08:26:56 and 08:49:52) by its own first words, with no cue before it, and then
played every later reply to the end. That is the canceller not yet converged
on its first playback, as Apple's thread describes. Builds 12 to 22 faded each
reply in over 200 ms (`a4bff61`), which hid it. The fade was removed in
`1b0a6f5` because it clipped the start of speech, and nothing may clip or
attenuate it. That is the leak the echo matching below was built for ("Hi
Adam, I can hear you loud and clear").

## Echo matching: tried and removed

`0233697` to `53a92be` (merged in `29b1107`) dropped recognizer results that
were the reply's own words heard back. `ReplyEcho` counted heard text as echo
when two thirds of its words, rounded up, lined up in order with a stretch of
the reply two words longer, and the loop also dropped the last reply's echo up
to half a second after it ended, while the next reply played.

It was reverted in full (`55bbcb2`). The two-thirds rule, the two-word slack
and the half-second margin are guesses, not measurements, and they decide
whether Adam's words are sent or dropped. When one guesses wrong, a real
interruption is lost or echo still cuts a reply off, and the logs, which keep
no words, can't show whether what was dropped was echo or Adam: those bugs
would be very hard to track down.
Nothing else in the merge stood on its own, so the code went back to `7cc0e21`.

The working cue stays the likely cause of builds 41 and 43. The loop now never
plays it with a reply: it waits until a reply's sound has ended, starting a
tenth of a second after it, and a reply that starts while it plays stops it at
once. Whether that, or dropping the cue entirely, keeps the canceller converged
has to be checked on the phone. Echo cancellation itself (voice processing, the
voice chat mode, one engine for the microphone, speech and cues) is unchanged.

## Trying it on the Mac

The same set-up on a MacBook Pro's built-in speakers and microphone (an
`AVAudioEngine` with voice processing, a speech player and a cue player at
48 kHz mono, the mixer connected at the input's rate) didn't reproduce either
leak. With or without a cue three seconds before, the start of the speech left
the microphone at -75 to -100 dBFS, at or under the room's noise. The Mac's
canceller is tuned differently from the iPhone's speakerphone, so it can't
stand in for the phone.

[apple]: https://developer.apple.com/forums/thread/829784
