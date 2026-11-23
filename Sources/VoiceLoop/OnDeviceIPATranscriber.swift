import Foundation
import FoundationModels
import Logging
import LogSupport

/// One word of a chunk as an `IPATranscriber` wrote it: the word, and its pronunciation in
/// standard IPA for American English.
public struct TranscribedWord: Hashable, Sendable {
    public var word: String
    public var ipa: String

    public init(word: String, ipa: String) {
        self.word = word
        self.ipa = ipa
    }
}

/// Writes the IPA for each word of a chunk of text, for Speak IPA. The app has one on-device
/// backend (`OnDeviceIPATranscriber`); tests use a fake.
public protocol IPATranscriber: Sendable {
    /// Whether it can transcribe now, and if not, why, as the pronunciation suggester's.
    var availability: PronunciationSuggesterAvailability { get }
    /// Each word of `chunk`, in order, with its IPA, as the model wrote them: it can leave a word
    /// out, add one, or write symbols Kokoro doesn't have, which
    /// `SpeakIPAText.parts(of:transcribed:symbols:)` sorts out. Throws a
    /// `PronunciationSuggestionError`, or `CancellationError` once cancelled. `request` and
    /// `chunkIndex` number it in the logs, as Speak IPA does.
    func transcribe(_ chunk: String, request: Int, chunkIndex: Int) async throws -> [TranscribedWord]
}

/// Transcribes with Apple's on-device language model (`SystemLanguageModel.default`), with no
/// network and no key, as `OnDevicePronunciationSuggester` suggests: it is asked for standard IPA,
/// which it knows far better than Kokoro's notation, word by word, and
/// `MisakiPhonemes.fromIPA(_:asOneWord:)` converts each afterwards.
///
/// The answer is a list of words, each with its IPA (guided generation, `@Generable`), not one
/// string of IPA for the whole chunk: measured on macOS 27, the model's guardrails declined every
/// whole-sentence answer as unsafe, while the word list passed every time, and it lets each word's
/// IPA be matched to the word it is for. Its symbols aren't held to Kokoro's by a guide: the
/// guides take no character class, and an alternation of the symbols made a 17-word sentence take
/// 69 s rather than about 4.5. A symbol Kokoro doesn't have puts that word back to Kokoro's own
/// reading instead.
///
/// Each step is logged under `voice.speakipa` at notice level, and a failure at warning, with the
/// request's and chunk's numbers and the time since it started (`ms`): the availability check,
/// the session, the request sent, the first part of the answer, then the answer, a failure or the
/// cancel. Counts, sizes and codes only: the text and what the model wrote are the user's.
public struct OnDeviceIPATranscriber: IPATranscriber {
    private static let log = Logger(label: "voice.speakipa")

    public init() {}

    public var availability: PronunciationSuggesterAvailability {
        OnDevicePronunciationSuggester.availability(of: SystemLanguageModel.default.availability)
    }

    public func transcribe(_ chunk: String, request: Int, chunkIndex: Int) async throws -> [TranscribedWord] {
        let started = ContinuousClock.now
        let model = SystemLanguageModel.default
        let availability = OnDevicePronunciationSuggester.availability(of: model.availability)
        var fields: [String: CustomStringConvertible] = ["request": request, "chunk": chunkIndex]
        func logged(_ extra: [String: CustomStringConvertible] = [:]) -> [String: CustomStringConvertible] {
            fields.merging(extra) { $1 }.merging(["ms": Self.milliseconds(since: started)]) { $1 }
        }
        Self.log.notice("speak ipa model checked", logged([
            "availability": availability.logName,
            "contextSize": model.contextSize,
        ]))
        if case .unavailable(let reason) = availability {
            throw PronunciationSuggestionError.unavailable(reason)
        }
        // A session of its own for each chunk, so the context holds only this one, and a chunk is
        // never transcribed in light of what the model wrote for another.
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        let words = SpeakIPAText.words(of: chunk).count
        let maximumResponseTokens = Self.maximumResponseTokens(forWords: words)
        fields["words"] = words
        // Sizes only: the prompt is the user's text.
        Self.log.notice("speak ipa session created", logged([
            "instructionsChars": Self.instructions.count,
            "promptChars": chunk.count,
            "maximumResponseTokens": maximumResponseTokens,
        ]))
        var snapshots = 0
        let transcribed: [TranscribedWord]
        do {
            let stream = session.streamResponse(
                to: chunk,
                generating: GeneratedTranscription.self,
                options: GenerationOptions(maximumResponseTokens: maximumResponseTokens)
            )
            Self.log.notice("speak ipa request started", logged())
            for try await _ in stream {
                snapshots += 1
                if snapshots == 1 {
                    Self.log.notice("speak ipa answer started", logged())
                }
            }
            // A request cancelled as its answer finished is still cancelled.
            try Task.checkCancellation()
            let response = try await stream.collect()
            transcribed = response.content.words.map { TranscribedWord(word: $0.word, ipa: $0.ipa) }
            var answerFields: [String: CustomStringConvertible] = ["snapshots": snapshots, "generated": transcribed.count]
            if #available(iOS 27.0, macOS 27.0, *) {
                answerFields["promptTokens"] = response.usage.input.totalTokenCount
                answerFields["answerTokens"] = response.usage.output.totalTokenCount
            }
            Self.log.notice("speak ipa answer generated", logged(answerFields))
        } catch {
            // The model may throw an error of its own once the request is cancelled.
            if error is CancellationError || Task.isCancelled {
                Self.log.notice("speak ipa request cancelled", logged(["snapshots": snapshots]))
                throw CancellationError()
            }
            var reason = OnDevicePronunciationSuggester.reason(for: error)
            // Its assets go missing when Apple Intelligence is turned off, too: what the model
            // says of itself now tells which.
            if case .unavailable = reason,
               case .unavailable(let now) = OnDevicePronunciationSuggester.availability(of: model.availability) {
                reason = .unavailable(now)
            }
            // Codes only: the model's messages can quote the text.
            Self.log.warning("speak ipa request failed", error.logCodes(
                logged(["snapshots": snapshots, "reason": reason.logName]).mapValues(\.description)
            ))
            throw reason
        }
        return transcribed
    }

    /// Room for about 24 tokens a word, the structure around each included, and a little more,
    /// so an answer that runs on fails rather than fills the context. The model wrote about 14 a
    /// word on macOS 27.
    static func maximumResponseTokens(forWords words: Int) -> Int {
        min(100 + 24 * words, 3_000)
    }

    /// The example keeps it to one entry a word, and to the vowels the conversion reads.
    private static let instructions = """
        You transcribe English text into IPA for a text-to-speech voice with an American accent. \
        List every word of the text, in order, each with its IPA. Never leave out, add, join, or \
        translate a word.
        Mark the stressed syllable with ˈ before it, and a secondary stress with ˌ. Write the vowel \
        of say as eɪ, of bed as ɛ, and of go as oʊ.

        Example, for: Hi there, Joaquin.
        word Hi; ipa haɪ
        word there; ipa ðɛɹ
        word Joaquin; ipa wɑˈkin
        """

    /// What the model's answer is: the text's words, each with its IPA.
    @Generable
    struct GeneratedTranscription {
        @Guide(description: "Each word of the text, in order, with its IPA")
        var words: [GeneratedWord]
    }

    /// One word as the model writes it: the word first, so the IPA follows from it.
    @Generable
    struct GeneratedWord {
        @Guide(description: "One word of the text, as written")
        var word: String
        // Not held to IPA's symbols with a pattern guide: see the type's documentation.
        @Guide(description: "That word in standard IPA for American English, such as wɑˈkin")
        var ipa: String
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int(start.duration(to: .now) / .milliseconds(1))
    }
}
