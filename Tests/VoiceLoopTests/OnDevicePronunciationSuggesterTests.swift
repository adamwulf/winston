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
    private func suggestions(_ ipa: String, for word: String) -> [PronunciationSuggestion] {
        OnDevicePronunciationSuggester.suggestions(
            from: .init(respelling: "WIN-stun", ipa: ipa, note: "the usual way"),
            for: word
        )
    }

    /// The phonemes of each suggestion for `ipa`.
    private func phonemes(_ ipa: String, for word: String) -> [String] {
        suggestions(ipa, for: word).map(\.phonemes)
    }

    @Test func itCreditsAppleIntelligenceOnThisDevice() {
        #expect(OnDevicePronunciationSuggester().attribution == "Suggested by Apple Intelligence on this device.")
    }

    @Test func itsIPAIsInKokorosNotationWithItsRespellingAndNote() {
        #expect(suggestions("ˈwɪn.stən", for: "Winston") == [PronunciationSuggestion(phonemes: "wˈɪnstən", respelling: "WIN-stun", note: "the usual way")])
    }

    @Test func theIPAOfOneWordIsOneWordThoughTheModelSpacedItsSyllables() {
        #expect(phonemes("ˈwɪn stən", for: " Winston ") == ["wˈɪnstən"])
        // The space breaks syllables: joined, o and ɪ would be the diphthong of "boy".
        #expect(phonemes("ˈɡo ɪŋ", for: "going") == ["ɡˈOɪŋ"])
        // Several words keep their spaces.
        #expect(phonemes("ˈnu ˈjɔrk", for: "New York") == ["nˈu jˈɔɹk"])
    }

    @Test func anOptionalSoundGivesASuggestionWithoutItAndOneWithIt() {
        // As the model wrote Siobhan.
        let siobhan = suggestions("ˈsɪːbə(h)n", for: "Siobhan")
        #expect(siobhan.map(\.phonemes) == ["sˈɪbən", "sˈɪbəhn"])
        #expect(siobhan.allSatisfy { $0.respelling == "WIN-stun" && $0.note == "the usual way" })
        // Both can be used, one heard after the other.
        let candidates = PronunciationCandidate.candidates(from: siobhan, symbols: MisakiPhonemes.usSymbols)
        #expect(candidates.map(\.isUsable) == [true, true])
    }

    @Test func eachOptionalSoundIsReadBothWaysAndARepeatIsDroppedAfterward() {
        #expect(phonemes("ˈ(h)wɪ(t)ʃ", for: "which") == ["wˈɪʃ", "wˈɪʧ", "hwˈɪʃ", "hwˈɪʧ"])
        // An optional sound that makes no difference gives the same phonemes twice; the list
        // shows them once.
        let same = suggestions("ˈkæ(ː)t", for: "cat")
        #expect(same.map(\.phonemes) == ["kˈæt", "kˈæt"])
        #expect(PronunciationCandidate.candidates(from: same, symbols: MisakiPhonemes.usSymbols).count == 1)
    }
}

/// Whether `OnDevicePronunciationSuggesterRealModelTests` was asked for: with
/// `WINSTON_SUGGESTER_REAL_MODEL=1`, or with a file named `suggester-real-model` in the package's
/// `.build` folder, which git ignores (for where setting a variable is awkward, as
/// `KokoroLoadTimingTests` takes `timing-models.txt`). It is off by default: it spends about 25 s
/// on the model, beside suites that time things, and its answers differ from run to run.
private let realSuggesterRequested: Bool = {
    if ProcessInfo.processInfo.environment["WINSTON_SUGGESTER_REAL_MODEL"] == "1" {
        return true
    }
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return FileManager.default.fileExists(atPath: package.appending(path: ".build/suggester-real-model").path)
}()

/// The real on-device model, run only when asked for (`realSuggesterRequested`) and where it can
/// run (Apple Intelligence on and its model downloaded): it prints what it suggests for a few
/// words, for a person to judge, as the suggestions settings would list. The phonemes are checked
/// against misaki's US symbols, as they are while the Kokoro model isn't loaded.
///
/// A word is a failure if the model fails on it or gives it no usable suggestion. Each is
/// reported, and the check fails only past two: the model fails now and then on its own, about 2
/// requests in 70 so far. Its guardrails declined "Nguyen" once and answered it the other times,
/// and nothing turns them off for a @Generable answer; once it ran on writing for Siobhan until
/// `maximumResponseTokens` cut it off, and its answer couldn't be read. Settings shows either as a
/// message, and Regenerate asks again. A mistake of ours, such as a guide the model doesn't take,
/// fails every word.
@Suite(
    .serialized,
    .enabled(if: realSuggesterRequested, "neither WINSTON_SUGGESTER_REAL_MODEL=1 nor .build/suggester-real-model asks for it"),
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
                from: generated.flatMap { OnDevicePronunciationSuggester.suggestions(from: $0, for: word) },
                symbols: MisakiPhonemes.usSymbols
            )
            report.append("\(word) (\(seconds.formatted(.number.precision(.fractionLength(1)))) s, \(generated.count) generated, \(candidates.count) after dropping repeats):")
            // The phonemes reported so far: a suggestion with the same ones again was dropped.
            var reported: Set<String> = []
            for pronunciation in generated {
                // One line for each reading of its optional sounds.
                for suggestion in OnDevicePronunciationSuggester.suggestions(from: pronunciation, for: word) {
                    let candidate = candidates.first { $0.suggestion.phonemes == suggestion.phonemes }
                    let isRepeat = candidate.map { !reported.insert($0.id).inserted } ?? false
                    let status = switch candidate {
                    case nil: "empty, dropped"
                    case _ where isRepeat: "repeat, dropped"
                    case let candidate? where candidate.isUsable: "usable"
                    case let candidate?: "unknown symbols: \(String(candidate.unknownSymbols))"
                    }
                    report.append("  \(pronunciation.respelling) | IPA \(pronunciation.ipa) → \(suggestion.phonemes) | \(pronunciation.note) | \(status)")
                }
            }
            // Not 3 to 5, though the guide asks for that: the model gave Kokoro 2 once.
            if !candidates.contains(where: \.isUsable) {
                report.append("  no usable suggestion")
                failedWords.append(word)
            }
        }
        print(report.joined(separator: "\n"))
        #expect(failedWords.count <= 2, "the model failed on \(failedWords)")
    }
}
