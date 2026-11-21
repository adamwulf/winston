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
/// turned off, or while its model downloads: `availability` says which.
///
/// Each step of a request is logged under `voice.suggestions` at notice level, and a failure at
/// warning, with the request's number and the time since it started (`ms`): the availability
/// check, the session, the request sent, the first part of the answer to stream in, each new
/// pronunciation as it starts, then the answer, a failure or the cancel, and the conversion to
/// Kokoro's notation. Counts, sizes and codes only: the word and what the model wrote are the
/// user's.
public struct OnDevicePronunciationSuggester: PronunciationSuggester {
    private static let log = Logger(label: "voice.suggestions")

    public init() {}

    public var availability: PronunciationSuggesterAvailability {
        Self.availability(of: SystemLanguageModel.default.availability)
    }

    public var attribution: String {
        "Suggested by Apple Intelligence on this device."
    }

    public func suggestions(for word: String, request: Int) async throws -> [PronunciationSuggestion] {
        let started = ContinuousClock.now
        let generated = try await generatedPronunciations(for: word, request: request, started: started)
        let suggestions = generated.flatMap { Self.suggestions(from: $0, for: word) }
        Self.log.notice("pronunciation IPA converted", [
            "request": request,
            "generated": generated.count,
            "suggestions": suggestions.count,
            "ms": Self.milliseconds(since: started),
        ])
        return suggestions
    }

    /// `availability` as a suggester's: the same reasons, and one newer than this code as
    /// `.other`.
    static func availability(of availability: SystemLanguageModel.Availability) -> PronunciationSuggesterAvailability {
        guard case .unavailable(let reason) = availability else { return .available }
        switch reason {
        case .deviceNotEligible: return .unavailable(.deviceNotEligible)
        case .appleIntelligenceNotEnabled: return .unavailable(.appleIntelligenceNotEnabled)
        case .modelNotReady: return .unavailable(.modelNotReady)
        @unknown default: return .unavailable(.other)
        }
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

    /// The model's pronunciations of `word`, as it writes them. The answer is streamed, though
    /// only the whole of it is used, so the logs show how far a slow request got. `request`
    /// numbers the request in the logs, as the suggestion list does, and `started` is when it
    /// began, for the logs' times.
    func generatedPronunciations(
        for word: String,
        request: Int,
        started: ContinuousClock.Instant = .now
    ) async throws -> [GeneratedPronunciation] {
        let model = SystemLanguageModel.default
        let availability = Self.availability(of: model.availability)
        Self.log.notice("pronunciation model checked", [
            "request": request,
            "availability": availability.logName,
            "supportsLocale": model.supportsLocale(),
            "ms": Self.milliseconds(since: started),
        ])
        if case .unavailable(let reason) = availability {
            throw PronunciationSuggestionError.unavailable(reason)
        }
        // A session of its own for each word, so no word is answered in light of another, and a
        // regenerate never finds the session busy.
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        let prompt = "Suggest pronunciations for: \(word)"
        // Sizes only: the prompt holds the word.
        Self.log.notice("pronunciation session created", [
            "request": request,
            "instructionsChars": Self.instructions.count,
            "promptChars": prompt.count,
            "maximumResponseTokens": Self.maximumResponseTokens,
            "ms": Self.milliseconds(since: started),
        ])
        var progress = StreamProgress(request: request, started: started)
        let pronunciations: [GeneratedPronunciation]
        do {
            let stream = session.streamResponse(
                to: prompt,
                generating: GeneratedPronunciations.self,
                options: GenerationOptions(maximumResponseTokens: Self.maximumResponseTokens)
            )
            // Sent: from here, the model has it until its first snapshot.
            Self.log.notice("pronunciation request started", progress.logFields)
            for try await snapshot in stream {
                progress.note(snapshot)
            }
            // A request cancelled as its answer finished is still cancelled.
            try Task.checkCancellation()
            pronunciations = try await stream.collect().content.pronunciations
        } catch {
            // The model may throw an error of its own once the request is cancelled.
            if error is CancellationError || Task.isCancelled {
                Self.log.notice("pronunciation suggestions cancelled", progress.logFields)
                throw CancellationError()
            }
            var reason = Self.reason(for: error)
            // Its model's assets go missing when Apple Intelligence is turned off, too: what the
            // model says of itself now tells which.
            if case .unavailable = reason, case .unavailable(let now) = Self.availability(of: model.availability) {
                reason = .unavailable(now)
            }
            // Codes only: the model's messages can quote the word.
            Self.log.warning("pronunciation suggestions failed", error.logCodes(
                progress.logFields.mapValues(\.description).merging(["reason": reason.logName]) { $1 }
            ))
            throw reason
        }
        // Counts only: the word, the model's answers and their phonemes are the user's.
        Self.log.notice("pronunciation suggestions generated", progress.logFields.merging([
            "suggestions": pronunciations.count,
        ]) { $1 })
        return pronunciations
    }

    /// How far a request's streamed answer has come, for the logs: it logs the first snapshot and
    /// each new pronunciation as the model starts it.
    private struct StreamProgress {
        let request: Int
        let started: ContinuousClock.Instant
        /// The snapshots streamed so far.
        private(set) var snapshots = 0
        /// The pronunciations the model has started so far.
        private(set) var pronunciations = 0
        /// The tokens of the prompt, with the instructions and the schema, and of the answer so
        /// far: nil before iOS 27 and macOS 27, which don't report them.
        private var promptTokens: Int?
        private var answerTokens: Int?

        init(request: Int, started: ContinuousClock.Instant) {
            self.request = request
            self.started = started
        }

        mutating func note(_ snapshot: LanguageModelSession.ResponseStream<GeneratedPronunciations>.Snapshot) {
            snapshots += 1
            if #available(iOS 27.0, macOS 27.0, *) {
                promptTokens = snapshot.usage.input.totalTokenCount
                answerTokens = snapshot.usage.output.totalTokenCount
            }
            if snapshots == 1 {
                OnDevicePronunciationSuggester.log.notice("pronunciation answer started", logFields)
            }
            let begun = snapshot.content.pronunciations?.count ?? 0
            if begun > pronunciations {
                pronunciations = begun
                OnDevicePronunciationSuggester.log.notice("pronunciation answer progress", logFields)
            }
        }

        var logFields: [String: CustomStringConvertible] {
            var fields: [String: CustomStringConvertible] = [
                "request": request,
                "snapshots": snapshots,
                "pronunciations": pronunciations,
                "ms": OnDevicePronunciationSuggester.milliseconds(since: started),
            ]
            if let promptTokens {
                fields["promptTokens"] = promptTokens
            }
            if let answerTokens {
                fields["answerTokens"] = answerTokens
            }
            return fields
        }
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

    /// What the model's answer to `suggestions(for:request:)` is: its pronunciations.
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

    /// The `PronunciationSuggestionError` for a failure of the model's, or of ours. Its assets
    /// missing is taken as its model not ready, as while it downloads; `generatedPronunciations`
    /// then asks the model why it is unavailable, and keeps that reason if it has one.
    static func reason(for error: any Error) -> PronunciationSuggestionError {
        if let error = error as? PronunciationSuggestionError {
            return error
        }
        if #available(iOS 27.0, macOS 27.0, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .guardrailViolation, .refusal: return .declined
                case .rateLimited: return .busy
                case .timeout: return .timedOut
                default: return .failed
                }
            }
            if error is LanguageModelSession.Error {
                return .busy
            }
            if error is SystemLanguageModel.Error {
                return .unavailable(.modelNotReady)
            }
        }
        // What the model throws on iOS 26 and macOS 26.
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: return .declined
            case .rateLimited, .concurrentRequests: return .busy
            case .assetsUnavailable: return .unavailable(.modelNotReady)
            default: return .failed
            }
        }
        return .failed
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int(start.duration(to: .now) / .milliseconds(1))
    }
}
