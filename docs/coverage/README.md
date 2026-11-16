# Coverage

One report per run, named for the day it ran (`YYYY-MM-DD.md`, US Central).
The latest is [2026-11-15](2026-11-15.md): 91.4% of lines, 97.2% outside the
calls into the system.

## Goals

- Every line in `Sources/` runs under a test, except the thin calls into the
  system listed in the README's [Coverage](../../README.md#coverage) section.
- Those calls stay thin, so all that goes uncovered is the call itself. New
  logic goes where a test can reach it: not in a `Live…` file, and not in
  `App/`.
- Coverage shows behavior no test checks. It isn't a score: a test checks what
  the code did, and is never written only to run lines.
- Each report is compared with the last. A file that lost coverage gets a test,
  or the report says why it can't.

## Testing

- **Test the real production code.** The tests drive the same types the app
  uses, through their public API: `AppModel` on top of the real `TelegramLink`
  and `VoiceLoop`.
- **Test real production flows.** Run a whole flow as the app does (log in, load
  a chat, send, listen, speak), and assert what it did: the requests TDLib
  received, the state that was published, what was spoken.
- **Never copy code into a test.** A test doesn't restate production logic to
  get its expected value, and doesn't rebuild a piece of production code to test
  that instead.
- **Small seams, only when needed.** A seam replaces only what a test process
  can't have: a network service, hardware, a permission prompt, a large model,
  the passing of time, the app's user defaults. If the real thing can run in a
  test, it runs: the audio engines run in offline rendering mode, and the real
  `AVSpeechSynthesizer` speaks.
- A seam is as narrow as the call it replaces, and is declared `package` so
  the app can't see it. Its stand-in lives in a `…TestSupport` target that every
  test target shares, and behaves like the real thing at that boundary:
  `FakeTDLib` walks TDLib's login states and sends updates as TDLib's JSON.
  Everything on both sides of a seam is production code.
- The README's [What the tests run](../../README.md#what-the-tests-run) lists
  every seam and its stand-in. A new seam is added there.

## Making a report

Run on a commit with no uncommitted changes, so the hash names what was
measured.

1. macOS, with every test bundle merged and only `Sources/` counted:

   ```sh
   Scripts/coverage.sh
   ```

   Every test must pass. The table it prints is the report's source.

2. iOS, for the code inside `#if os(iOS)` that macOS doesn't compile:

   ```sh
   xcodebuild test -workspace App/Winston.xcworkspace -scheme Winston \
     -destination "platform=iOS Simulator,name=iPhone 17" \
     -derivedDataPath DerivedData -resultBundlePath DerivedData/ios-tests.xcresult
   xcrun xccov view --report --only-targets DerivedData/ios-tests.xcresult
   ```

   Xcode reports coverage per binary. A library with a row of its own is
   complete there; the others are linked into the test bundles, whose rows
   count test files too, so iOS has no single `Sources/` total. (Xcode Cloud's
   test log prints the same per-binary report.)

3. Write `docs/coverage/YYYY-MM-DD.md`, starting with:

   ```yaml
   ---
   date: YYYY-MM-DD
   commit: <git rev-parse HEAD>
   line_coverage: <the macOS TOTAL line coverage>
   ---
   ```

   Then the same sections as the last report: a summary by library, what is
   uncovered on purpose and the total without it, gaps worth a look, every
   file, and iOS. Note what changed since the last report.

4. Update the latest report's link at the top of this file.
