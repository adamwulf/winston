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

/// The real on-device model, skipped unless it can run here (Apple Intelligence on and its model
/// downloaded): it prints what it suggests for a few words, for a person to judge, as the
/// suggestions settings would list. The phonemes are checked against misaki's US symbols, as
/// they are while the Kokoro model isn't loaded.
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
        for word in Self.words {
            let started = ContinuousClock.now
            let generated: [OnDevicePronunciationSuggester.GeneratedPronunciation]
            do {
                generated = try await suggester.generatedPronunciations(for: word)
            } catch {
                report.append("\(word): failed, \(OnDevicePronunciationSuggester.reason(for: error)) (\(error))")
                Issue.record(error, "\(word)")
                continue
            }
            let seconds = Double(started.duration(to: .now) / .milliseconds(1)) / 1000
            let candidates = PronunciationCandidate.candidates(
                from: generated.map(OnDevicePronunciationSuggester.suggestion(from:)),
                symbols: MisakiPhonemes.usSymbols
            )
            report.append("\(word) (\(seconds.formatted(.number.precision(.fractionLength(1)))) s, \(generated.count) generated, \(candidates.count) after dropping repeats):")
            for pronunciation in generated {
                let suggestion = OnDevicePronunciationSuggester.suggestion(from: pronunciation)
                let candidate = candidates.first { $0.suggestion.phonemes == suggestion.phonemes }
                let status = switch candidate {
                case nil: "repeat or empty, dropped"
                case let candidate? where candidate.isUsable: "usable"
                case let candidate?: "unknown symbols: \(String(candidate.unknownSymbols))"
                }
                report.append("  \(pronunciation.respelling) | IPA \(pronunciation.ipa) → \(suggestion.phonemes) | \(pronunciation.note) | \(status)")
            }
            #expect((3...5).contains(generated.count), "\(word)")
            #expect(!candidates.isEmpty, "\(word)")
        }
        print(report.joined(separator: "\n"))
    }
}
