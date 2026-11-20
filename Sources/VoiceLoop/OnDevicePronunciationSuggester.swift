import Foundation
import FoundationModels
import Logging
import LogSupport

/// Suggests pronunciations with Apple's on-device language model (`SystemLanguageModel.default`),
/// with no network and no key. The model knows standard IPA far better than Kokoro's notation, so
/// it is asked for IPA for American English, and each answer is converted to Kokoro's notation
/// here (`MisakiPhonemes.fromIPA(_:)`).
///
/// The model isn't there on a device without Apple Intelligence, while Apple Intelligence is
/// turned off, or while its model downloads: `isAvailable` says so.
public struct OnDevicePronunciationSuggester: PronunciationSuggester {
    private static let log = Logger(label: "voice.suggestions")

    public init() {}

    public var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    public var attribution: String {
        "Suggested by Apple Intelligence on this device."
    }

    public func suggestions(for word: String) async throws -> [PronunciationSuggestion] {
        try await generatedPronunciations(for: word).flatMap { Self.suggestions(from: $0, for: word) }
    }

    /// `pronunciation` of `word` in Kokoro's notation: a suggestion for each reading of its
    /// optional sounds, such as the (h) of "ˈsɪbə(h)n" (see `MisakiPhonemes.readings(ofIPA:)`),
    /// so each can be heard, with the same respelling and note. The model sometimes puts a space
    /// between the syllables of one word ("ˈwɪn stən"), which Kokoro would say as two, so the IPA
    /// of a word without spaces is one word, its spaces syllable breaks.
    static func suggestions(from pronunciation: GeneratedPronunciation, for word: String) -> [PronunciationSuggestion] {
        let isOneWord = !word.trimmingCharacters(in: .whitespacesAndNewlines).contains(where: \.isWhitespace)
        return MisakiPhonemes.readings(ofIPA: pronunciation.ipa).map { ipa in
            PronunciationSuggestion(
                phonemes: MisakiPhonemes.fromIPA(ipa, asOneWord: isOneWord),
                respelling: pronunciation.respelling,
                note: pronunciation.note
            )
        }
    }

    /// The model's pronunciations of `word`, as it writes them.
    func generatedPronunciations(for word: String) async throws -> [GeneratedPronunciation] {
        let model = SystemLanguageModel.default
        if case .unavailable(let reason) = model.availability {
            Self.log.notice("pronunciation suggestions unavailable", ["reason": Self.name(of: reason)])
            throw PronunciationSuggestionError.unavailable
        }
        let started = ContinuousClock.now
        // A session of its own for each word, so no word is answered in light of another, and a
        // regenerate never finds the session busy.
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        let pronunciations: [GeneratedPronunciation]
        do {
            pronunciations = try await session.respond(
                to: "Suggest pronunciations for: \(word)",
                generating: GeneratedPronunciations.self,
                options: GenerationOptions(maximumResponseTokens: Self.maximumResponseTokens)
            ).content.pronunciations
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let reason = Self.reason(for: error)
            // Codes only: the model's messages can quote the word.
            Self.log.warning("pronunciation suggestions failed", error.logCodes([
                "reason": reason.rawValue,
                "ms": String(Self.milliseconds(since: started)),
            ]))
            throw reason
        }
        // Counts only: the word, the model's answers and their phonemes are the user's.
        Self.log.info("pronunciation suggestions generated", [
            "suggestions": pronunciations.count,
            "ms": Self.milliseconds(since: started),
        ])
        return pronunciations
    }

    /// Room for five pronunciations several times over, so a model that won't stop writing one
    /// fails rather than runs on.
    private static let maximumResponseTokens = 800

    /// With rules and a worked example: without them, the model often wrote the same IPA several
    /// times, each with a made-up note on stress.
    private static let instructions = """
        You help a text-to-speech voice say words and names correctly for American listeners. \
        Given a word, list different ways people say it, the most likely first.

        Rules:
        - Every pronunciation must sound different from the others. Never repeat one.
        - If you know only one way to say the word, make the others its likeliest other \
        readings: as it is spelled, with the stress on another syllable, or with another vowel.
        - For a name or a word from another language, give the way its speakers say it first.
        - For a word made of two words, say each part as the word it comes from.
        - The IPA must say exactly what its respelling says.

        Example, for Joaquin, three pronunciations:
        respelling wah-KEEN; ipa wɑˈkin; note Spanish name, the usual way
        respelling hwah-KEEN; ipa hwɑˈkin; note closer to Spanish
        respelling JOH-uh-kin; ipa ˈdʒoʊəkɪn; note read as it is spelled
        """

    /// What the model's answer to `suggestions(for:)` is: its pronunciations.
    @Generable
    struct GeneratedPronunciations {
        @Guide(description: "Different ways to say the word, the most likely first", .count(3...5))
        var pronunciations: [GeneratedPronunciation]
    }

    /// One pronunciation, as the model writes it. The respelling comes first, so the IPA
    /// follows from it.
    @Generable
    struct GeneratedPronunciation {
        @Guide(description: "The pronunciation respelled in plain English letters, a hyphen between syllables, the stressed syllable in capitals, such as wah-KEEN")
        var respelling: String
        // Not held to IPA's symbols with a pattern guide: on macOS 27, the model takes neither a
        // character class nor anchors, and the alternation it does take, (?:p|b|…|ˈ|ˌ| )+, made
        // a request take 36 to 104 s rather than about 2. A symbol Kokoro doesn't have makes a
        // suggestion unusable instead (see `PronunciationCandidate`).
        // The vowels of "say" and "bed" as eɪ and ɛ, which the conversion reads that way: a bare
        // e is the vowel of "bed" to it.
        @Guide(description: "The same pronunciation in standard IPA for American English, with ˈ at the start of the stressed syllable and ˌ at the start of a syllable with secondary stress, such as wɑˈkin. Write the vowel of say as eɪ, of bed as ɛ, and of go as oʊ")
        var ipa: String
        @Guide(description: "A few words on who says it this way or where it comes from, such as: Spanish name, the usual way")
        var note: String
    }

    /// The `PronunciationSuggestionError` for a failure of the model's.
    static func reason(for error: any Error) -> PronunciationSuggestionError {
        if #available(iOS 27.0, macOS 27.0, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .guardrailViolation, .refusal: return .declined
                case .rateLimited, .timeout: return .busy
                default: return .failed
                }
            }
            if error is LanguageModelSession.Error {
                return .busy
            }
            if error is SystemLanguageModel.Error {
                return .unavailable
            }
        }
        // What the model throws on iOS 26 and macOS 26.
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: return .declined
            case .rateLimited, .concurrentRequests: return .busy
            case .assetsUnavailable: return .unavailable
            default: return .failed
            }
        }
        return .failed
    }

    /// `reason` as the logs name it.
    private static func name(of reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "deviceNotEligible"
        case .appleIntelligenceNotEnabled: "appleIntelligenceNotEnabled"
        case .modelNotReady: "modelNotReady"
        @unknown default: "unknown"
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int(start.duration(to: .now) / .milliseconds(1))
    }
}
