# Kokoro voices: download only the voices in use

Status: the "What to change" section is done, as of 2026-11-14 (speech-swift
pinned at `bd6905c`). The cheaper alternatives and related versioned marker
are not implemented.

## The cost before this change

`LiveKokoro` asked KokoroTTS for every American and British English voice
(`voiceFilter: ["a*", "b*"]`, 28 voices) whenever it downloaded or loaded a
masked or FluidAudio model. Settings offers 27 of them (`KokoroCatalog`; `am_santa`
is left out), but a reply only ever uses one.

Since `milestonemade/Kokoro-82M-CoreML-Masked` moved to voices with a style row
for each sentence length (Hub commit `d8b3a084`), each voice file is about
2.7 MB instead of about 5 KB. FluidAudio's voices were already that size. So:

- About 76 MB of each model's first download is voices, against about 3 MB for
  the one voice in use. The masked models' first download is about 320 MB; it
  would be about 245 MB.
- KokoroTTS parses every voice file on each load, about 70 ms a file on a Mac
  (measured by the speech-swift agent): about 2 s of each load, every launch,
  for voices that aren't used. The iPhone is likely slower.

soniqo's `kokoro_5s` isn't affected: its voices are about 5 KB each (one
averaged row), and it downloads all of them, as it always has.

## What to change

Pass `voiceFilter: [<the chosen voice>]` instead of `["a*", "b*"]`, so a model
downloads and parses only the voice in use.

- `KokoroEngine.load(_:voice:downloadProgress:)` takes the voice too, and
  `LiveKokoro` would pass it to `fromPretrained`. Today a load depends only on
  the model; it would depend on the model and the voice.
- `KokoroModel` would load again when the chosen Kokoro voice changes, not only
  when the model changes, the same way it already handles `variant` (a load under
  way finishes first, then the newly chosen one loads).
- Picking a voice not stored yet would download it (2.7 MB, a second or two)
  before it speaks. Until then the system voice speaks, as for a model download.
  A voice preview in settings would wait for that download too.
- The model's marker (`<folder>.<model>.downloaded`) says only that the model
  downloaded, not which voices. A voice not yet stored needs an online load, so
  either a marker per voice, or check for `voices/<voice>.json` before loading
  offline.
- The day-unused cleanup and the "Delete Downloaded Voice Models" button already
  delete whole folders, voices included; no change there.

## Cheaper alternatives

- Keep downloading all 28 but parse only the chosen one: halves nothing on disk,
  but saves the 2 s per load. Needs a speech-swift option to load voices lazily,
  or a filter for loading that is separate from the one for downloading.
- Narrow the filter to the voices `KokoroCatalog` offers for the current
  language (American or British, about 14 each): roughly halves both costs, with
  no load per voice change. A language change would then need a load.

## Related

- A stored model loads offline, so it doesn't pick up changed files on the Hub
  (the new per-length voices, for one). For now the settings button "Delete
  Downloaded Voice Models" is the way to refresh. A marker named with a version,
  bumped when the Hub files change, would make the next load go online once on
  its own.
