import Foundation
import Testing
@testable import VoiceLoop

@Suite struct OnDeviceIPATranscriberTests {
    @Test func theAnswerHasRoomForEachWordButNotForRunningOn() {
        #expect(OnDeviceIPATranscriber.maximumResponseTokens(forWords: 1) == 124)
        #expect(OnDeviceIPATranscriber.maximumResponseTokens(forWords: 45) == 1_180)
        #expect(OnDeviceIPATranscriber.maximumResponseTokens(forWords: 500) == 3_000)
    }
}

/// Whether to run the real model: with `WINSTON_SPEAKIPA_REAL_MODEL=1`, or, where setting an
/// environment variable is awkward, with a `speakipa-real-model` file in the package's `.build`
/// folder.
private let realTranscriberRequested: Bool = {
    if ProcessInfo.processInfo.environment["WINSTON_SPEAKIPA_REAL_MODEL"] == "1" {
        return true
    }
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return FileManager.default.fileExists(atPath: package.appending(path: ".build/speakipa-real-model").path)
}()

/// The real on-device model, run only when asked for (`realTranscriberRequested`) and where it can
/// run: it transcribes a reply as Speak IPA would, chunk by chunk, and prints each word's IPA, its
/// Kokoro phonemes and how long each chunk took, for a person to judge. The phonemes are checked
/// against misaki's US symbols, as they are while the Kokoro model isn't loaded.
///
/// It fails if more than one chunk fails, or if fewer than half the words of the chunks answered
/// got IPA from the model: a mistake of ours, such as a schema the model doesn't take, fails every
/// chunk. One failure is allowed: the guardrails now and then decline a harmless chunk (the one
/// with Siobhan and Joaquin, once), which Speak IPA says as written.
@Suite(
    .serialized,
    .enabled(if: realTranscriberRequested, "neither WINSTON_SPEAKIPA_REAL_MODEL=1 nor .build/speakipa-real-model asks for it"),
    .enabled(if: OnDeviceIPATranscriber().availability == .available, "the on-device language model isn't available"),
    .timeLimit(.minutes(5))
)
struct OnDeviceIPATranscriberRealModelTests {
    /// A reply like an agent's: markdown, numbers, a path, names.
    private static let reply = """
        ## Done

        I pushed the fix to `agent/speak-ipa` and reran the tests: all 214 passed in 3.5 s. \
        Siobhan and Joaquin arrived in Worcester on Tuesday, and they want to try the gnocchi. \
        Winston can read replies aloud with Kokoro, but some names still come out wrong.

        - Next: check ~/Developer/winston/README.md
        - Then ship it 🚀
        """

    @Test func itTranscribesAReplyChunkByChunk() async throws {
        let transcriber = OnDeviceIPATranscriber()
        let chunks = SpeakIPAText.chunks(in: SpeakIPAText.normalized(Self.reply))
        var report = ["", "Speak IPA on the on-device model (\(chunks.count) chunks):"]
        var words = 0
        var wordsWithIPA = 0
        var failedChunks = 0
        for (index, chunk) in chunks.enumerated() {
            let started = ContinuousClock.now
            let transcribed: [TranscribedWord]
            do {
                transcribed = try await transcriber.transcribe(chunk, request: 1, chunkIndex: index)
            } catch {
                // The transcriber's log line, above the report, has the model's error code.
                report.append("chunk \(index): failed, \(error): \(chunk)")
                failedChunks += 1
                continue
            }
            let seconds = Double(started.duration(to: .now) / .milliseconds(1)) / 1000
            let speech = SpeakIPAText.speech(of: chunk, transcribed: transcribed, symbols: MisakiPhonemes.usSymbols)
            words += speech.words
            wordsWithIPA += speech.wordsWithIPA
            let changes = speech.changes.map { "\($0.from)>\($0.to)" }.joined(separator: " ")
            report.append("chunk \(index) (\(seconds.formatted(.number.precision(.fractionLength(1)))) s, "
                + "\(speech.words) words, \(speech.generated) written, \(speech.wordsWithIPA) with IPA, "
                + "changed [\(changes)]): \(chunk)")
            report.append("  " + transcribed.map { "\($0.word)=\($0.ipa)" }.joined(separator: " "))
            report.append("  " + speech.parts.map { part in
                switch part {
                case .phonemes(let word, let phonemes): "[\(word):\(phonemes)]"
                case .text(let text): text
                }
            }.joined())
        }
        print(report.joined(separator: "\n"))
        #expect(failedChunks <= 1, "\(failedChunks) of \(chunks.count) chunks failed")
        #expect(wordsWithIPA * 2 >= words, "only \(wordsWithIPA) of \(words) words got IPA from the model")
    }
}
