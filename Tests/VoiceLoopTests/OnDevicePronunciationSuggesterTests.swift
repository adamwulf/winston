import Foundation
import FoundationModels
import Testing
@testable import VoiceLoop

/// What settings is told when the on-device model fails, whichever error type the system throws.
@Suite struct OnDevicePronunciationSuggesterErrorTests {
    private func reason(_ error: any Error) -> PronunciationSuggestionError {
        OnDevicePronunciationSuggester.reason(for: error)
    }

    @Test func iOS27AndMacOS27sErrorsAreSortedByWhatTheUserCanDo() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        #expect(reason(LanguageModelError.guardrailViolation(.init(debugDescription: ""))) == .declined)
        #expect(reason(LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: ""))) == .busy)
        #expect(reason(LanguageModelError.timeout(.init(debugDescription: ""))) == .busy)
        #expect(reason(LanguageModelSession.Error.concurrentRequests) == .busy)
        #expect(reason(SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: ""))) == .unavailable)
        #expect(reason(LanguageModelError.unsupportedLanguageOrLocale(.init(languageCode: "xx", debugDescription: ""))) == .failed)
    }

    @Test func iOS26AndMacOS26sErrorsAreSortedTheSameWay() {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "")
        #expect(reason(LanguageModelSession.GenerationError.guardrailViolation(context)) == .declined)
        #expect(reason(LanguageModelSession.GenerationError.rateLimited(context)) == .busy)
        #expect(reason(LanguageModelSession.GenerationError.concurrentRequests(context)) == .busy)
        #expect(reason(LanguageModelSession.GenerationError.assetsUnavailable(context)) == .unavailable)
        #expect(reason(LanguageModelSession.GenerationError.decodingFailure(context)) == .failed)
    }

    @Test func anyOtherErrorIsAFailure() {
        #expect(reason(CocoaError(.fileReadUnknown)) == .failed)
    }
}

/// What the on-device suggester makes of a pronunciation the model wrote.
@Suite struct OnDevicePronunciationSuggestionTests {
    private func suggestion(_ ipa: String, for word: String) -> PronunciationSuggestion {
        OnDevicePronunciationSuggester.suggestion(
            from: .init(respelling: "WIN-stun", ipa: ipa, note: "the usual way"),
            for: word
        )
    }

    @Test func itsIPAIsInKokorosNotationWithItsRespellingAndNote() {
        #expect(suggestion("ˈwɪn.stən", for: "Winston") == PronunciationSuggestion(phonemes: "wˈɪnstən", respelling: "WIN-stun", note: "the usual way"))
    }

    @Test func theIPAOfOneWordIsOneWordThoughTheModelSpacedItsSyllables() {
        #expect(suggestion("ˈwɪn stən", for: " Winston ").phonemes == "wˈɪnstən")
        // Several words keep their spaces.
        #expect(suggestion("ˈnu ˈjɔrk", for: "New York").phonemes == "nˈu jˈɔɹk")
    }
}

/// The real on-device model, skipped unless it can run here (Apple Intelligence on and its model
/// downloaded): it prints what it suggests for a few words, for a person to judge, as the
/// suggestions settings would list. The phonemes are checked against misaki's US symbols, as
/// they are while the Kokoro model isn't loaded.
///
/// A word the model fails on is reported, and the check fails only if it fails on more than two:
/// it fails now and then on its own, about 2 requests in 70 so far. Its guardrails declined
/// "Nguyen" once and answered it the other times, and nothing turns them off for a @Generable
/// answer; once it ran on writing for Siobhan until `maximumResponseTokens` cut it off, and its
/// answer couldn't be read. Settings shows either as a message, and Regenerate asks again. A
/// mistake of ours, such as a guide the model doesn't take, fails every word.
@Suite(
    .serialized,
    .enabled(if: OnDevicePronunciationSuggester().isAvailable, "the on-device language model isn't available"),
    .timeLimit(.minutes(5))
)
struct OnDevicePronunciationSuggesterRealModelTests {
    /// Words Adam wants said a certain way (in the comments), then names and loanwords.
    private static let words = [
        "winston", // "Win stun"
        "arrived", // "a rived"
        "itsybitsy", // "it see bit see"
        "Siobhan",
        "Nguyen",
        "Worcestershire",
        "gnocchi",
        "Saoirse",
        "quinoa",
        "Kokoro", // Kokoro's own dictionary: kˈOkəɹO
    ]

    @Test func itSuggestsAFewPronunciationsForEachWord() async throws {
        let suggester = OnDevicePronunciationSuggester()
        var report = ["", "On-device pronunciation suggestions (IPA from the model → Kokoro phonemes):"]
        var failedWords: [String] = []
        for word in Self.words {
            let started = ContinuousClock.now
            let generated: [OnDevicePronunciationSuggester.GeneratedPronunciation]
            do {
                generated = try await suggester.generatedPronunciations(for: word)
            } catch {
                // The suggester's log line, above the report, has the model's error code.
                report.append("\(word): failed, \(error)")
                failedWords.append(word)
                continue
            }
            let seconds = Double(started.duration(to: .now) / .milliseconds(1)) / 1000
            let candidates = PronunciationCandidate.candidates(
                from: generated.map { OnDevicePronunciationSuggester.suggestion(from: $0, for: word) },
                symbols: MisakiPhonemes.usSymbols
            )
            report.append("\(word) (\(seconds.formatted(.number.precision(.fractionLength(1)))) s, \(generated.count) generated, \(candidates.count) after dropping repeats):")
            for pronunciation in generated {
                let suggestion = OnDevicePronunciationSuggester.suggestion(from: pronunciation, for: word)
                let candidate = candidates.first { $0.suggestion.phonemes == suggestion.phonemes }
                let status = switch candidate {
                case nil: "repeat or empty, dropped"
                case let candidate? where candidate.isUsable: "usable"
                case let candidate?: "unknown symbols: \(String(candidate.unknownSymbols))"
                }
                report.append("  \(pronunciation.respelling) | IPA \(pronunciation.ipa) → \(suggestion.phonemes) | \(pronunciation.note) | \(status)")
            }
            // Not 3 to 5, though the guide asks for that: the model gave Kokoro 2 once.
            #expect(!candidates.isEmpty, "\(word)")
        }
        print(report.joined(separator: "\n"))
        #expect(failedWords.count <= 2, "the model failed on \(failedWords)")
    }
}
