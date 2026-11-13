# Kokoro voices: known gaps

Status: open, as of 2026-11-13, when the Kokoro voices merged (`9ec0473`).
None of these is a crash or data loss. They are left for later.

Kokoro's English phonemizer, in speech-swift's `KokoroTTS`, cannot read digits.
`KokoroNumbers` (`Sources/VoiceLoop/KokoroNumbers.swift`) turns numbers into
words before the text reaches Kokoro. System voices get the raw text. The rule
list on `KokoroNumbers.spelledOut(_:)` documents what it handles.

## Number formats it reads poorly

"Reads now" is `KokoroNumbers` output, checked at `9ec0473`. Kokoro is not
known to read the symbols that pass through (`°`, `+`, `~`, `#`, `:`), so they
are probably dropped. Each fix would go in `KokoroNumbers`, with a case in
`KokoroNumbersTests`.

| Case | Reads now | Should read | Suggested fix |
|---|---|---|---|
| `72°F`, `-5°C` | seventy-two°F, minus five°C | seventy-two degrees Fahrenheit, minus five degrees Celsius | Read `°`, `°F` and `°C` after a number as a unit. |
| `November 13, 2026` | November thirteen, twenty twenty-six | November thirteenth, twenty twenty-six | After a month name, read a day number of 1–31 as an ordinal. |
| `11/13/2026`, `11/13` | eleven thirteen two thousand twenty-six | November thirteenth, twenty twenty-six | Treat m/d/yyyy and m/d (month 1–12, day 1–31) as dates. |
| `Q3 2026` | Q three two thousand twenty-six | Q three, twenty twenty-six | Add a quarter (`Q1`–`Q4`) to the words that make the next four-digit number a year. |
| `1:02:03` | one oh two:zero three | one hour, two minutes, three seconds (or "one oh two oh three") | Recognize h:mm:ss before the h:mm time rule. |
| `17:00` | seventeen o'clock | seventeen hundred, or five PM | Read hours 13–23 as 24-hour time. |
| `2x faster`, `1.5x` | two x faster | two times faster | Read `x` right after a number as "times". |
| `100+` | one hundred+ | over one hundred (or one hundred plus) | Read a trailing `+` as "plus". |
| `~5` | ~five | about five | Read a leading `~` as "about". |
| `#1` | #one | number one | Read `#` before a number as "number". |
| `10km`, `5 mph`, `3kg` | ten km, five mph | ten kilometers, five miles per hour | Map the common unit abbreviations after a number, making them plural when the number is not 1. |
| `1/12` | one twelve | one twelfth | Extend the fractions to denominators above 10 when the numerator is smaller. |
| `3/4 million` | three quarters million | three quarters of a million | Add "of a" between a fraction and a scale word. |
| `Wait 30s` | thirty s | thirty seconds | Read an "Ns" with no decade context as seconds. Ranges already do this. |
| `5-10m` | five to ten m | five to ten meters, or million | Ambiguous: decided to leave it without money. Revisit if bots use it. |
| `5-10K`, `4K screen` | five to ten K | five to ten thousand (but "4K screen" stays "four K") | Ambiguous: decided that uppercase K stays a letter without money. |
| `$-5` | $-five | minus five dollars | Read a sign after the currency symbol. Decided to skip. |
| `file.25` | file.twenty-five | file dot twenty-five | Rare. Read `.` between a word and digits as "dot". |

## Other known gaps

- **Hyphenated words without digits.** The pinned phonemizer drops a hyphen
  without adding a space, so "a three-step plan" or "well-known" may run the two
  words together. `KokoroNumbers` handles hyphens next to digits only. Possible
  fix: turn a hyphen between two letters into a space for Kokoro.
- **British voices use American pronunciation.** `KokoroTTS.fromPretrained`
  loads only the US English dictionaries, so the `b*` voices have a British
  timbre but American pronunciation. This needs an upstream change, or loading
  the British dictionaries ourselves.
- **Pause between sentences.** Kokoro leaves about 0.2–0.45 s of silence at
  the end of each sentence, and it is kept as the pause between sentences. Trim
  it if replies sound slow.
- **No way to delete the model by hand.** The roughly 335 MB model in
  Application Support is deleted a day after the last Kokoro voice is unchosen
  (see the README's Kokoro voices section), but Settings has no "Remove
  download" button.
- **Pinned to a fork.** speech-swift is pinned to `adamwulf/speech-swift`
  `7cc2ddb` (branch `fix/kokoro-x86_64-float16`), which is upstream `31d676c`
  plus a fix that lets `KokoroTTS` compile for x86_64. Upstream reads float16
  outputs through Swift's `Float16`, which does not exist on Intel Macs, so the
  universal Mac archive fails there. Go back to `soniqo/speech-swift` only once
  that fix, or an equivalent one, is upstream.
- **Dependency weight.** speech-swift has no release tags, so it is pinned to a
  commit. SwiftPM builds only `KokoroTTS` and what it
  needs, but it still fetches and pins all of speech-swift's roughly 44
  dependencies. Both `Package.resolved` files grow by about 350 lines, and a cold
  resolve (Xcode Cloud) takes about 3 minutes. When updating the pin, check
  again that loading with `.cpuAndNeuralEngine` is still needed. `.all` aborted
  in MPSGraph on macOS 27.
- **A preview right after voice mode stops.** Stopping voice mode keeps its
  engine running for the stop cue, then deactivates the iOS audio session on a
  timer. A preview started in that half second plays on its own engine at the
  same time, and the timer's deactivation can cut it off. Possible fix: have
  `preview(_:)` call `endClosingPipeline()` before it starts, as a new start does.
- **Wall-clock test timing.** The Kokoro session suites run one test at a time
  (the `OneVoiceLoopAtATime` trait), because offline audio rendering on the
  shared main actor starved tests that time pauses by the clock. Other audio
  suites that time pauses by the clock could still fail on a heavily loaded
  machine.
