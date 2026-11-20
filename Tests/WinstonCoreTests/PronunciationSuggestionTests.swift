import Foundation
import Testing
import VoiceLoop
import VoiceLoopTestSupport
// For `PronunciationSuggestions`' own init, which takes the symbols to check against.
@testable import WinstonCore

/// The Suggest button on an IPA pronunciation in settings, and the list it opens: when it shows,
/// what the list shows, and using a suggestion.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PronunciationSuggestionTests {
    private func suggestion(_ phonemes: String, _ respelling: String = "", _ note: String = "") -> PronunciationSuggestion {
        PronunciationSuggestion(phonemes: phonemes, respelling: respelling, note: note)
    }

    /// The list's candidates once it has loaded, or nil.
    private func candidates(of suggestions: PronunciationSuggestions) -> [PronunciationCandidate]? {
        guard case .loaded(let candidates) = suggestions.phase else { return nil }
        return candidates
    }

    @Test func theSuggestButtonShowsOnlyWhileTheSuggesterCanRun() {
        let harness = Harness()

        harness.suggester.isAvailable = false
        #expect(!harness.model.canSuggestPronunciations)
        harness.suggester.isAvailable = true
        #expect(harness.model.canSuggestPronunciations)
    }

    @Test func suggestionsPlayOnlyWhileAKokoroVoiceIsReady() async {
        let harness = Harness()
        let model = harness.model

        // A system voice would say the same written word for every suggestion.
        #expect(!model.canPlaySuggestions)
        harness.bed.kokoro.loadBehavior = .waits
        model.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { harness.bed.kokoro.loads == 1 })
        // Until its model is ready, a Kokoro voice is spoken for by a system voice.
        #expect(!model.canPlaySuggestions)
        harness.bed.kokoro.finishLoading(succeeding: true)
        #expect(await eventually { model.voiceLoop.kokoroModelState == .ready })
        #expect(model.canPlaySuggestions)
        model.voiceIdentifier = nil
        #expect(!model.canPlaySuggestions)
    }

    @Test func theListLoadsThenShowsEachSuggestionOnceCheckedAgainstMisakisSymbols() async throws {
        let harness = Harness()
        harness.suggester.holdsAnswers = true
        harness.suggester.answers = [.success([
            suggestion("wˈɪnstən", "WIN-stun", "the usual way"),
            suggestion("wˈɪnstən", "WIN-ston", "a repeat"),
            suggestion("wˈɪnstɑx", "WIN-stokh", "with a symbol misaki lacks"),
        ])]
        let suggestions = harness.model.pronunciationSuggestions(for: " Winston ")

        // Nothing is asked until the list asks.
        #expect(harness.suggester.words.isEmpty)
        suggestions.generate()
        #expect(suggestions.phase == .loading)
        #expect(await eventually { harness.suggester.heldAnswers == 1 })
        #expect(harness.suggester.words == ["Winston"])
        harness.suggester.releaseAnswers()

        #expect(await eventually { suggestions.phase != .loading })
        let candidates = try #require(candidates(of: suggestions))
        // No Kokoro model is ready, so they are checked against misaki's symbols.
        #expect(candidates.map(\.suggestion) == [
            suggestion("wˈɪnstən", "WIN-stun", "the usual way"),
            suggestion("wˈɪnstɑx", "WIN-stokh", "with a symbol misaki lacks"),
        ])
        #expect(candidates.map(\.unknownSymbols) == [[], ["x"]])
    }

    @Test func withTheKokoroModelReadyTheyAreCheckedAgainstItsVocabulary() async throws {
        let harness = Harness()
        let model = harness.model
        harness.bed.kokoro.symbols = Set("lˈɑx")
        model.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { model.voiceLoop.kokoroModelState == .ready })
        harness.suggester.answers = [.success([suggestion("lˈɑx"), suggestion("wˈɪnstən")])]
        let suggestions = model.pronunciationSuggestions(for: "loch")

        suggestions.generate()

        #expect(await eventually { suggestions.phase != .loading })
        let candidates = try #require(candidates(of: suggestions))
        #expect(candidates.map(\.isUsable) == [true, false])
    }

    @Test func aFailureSaysWhyAndRegenerateAsksAgain() async throws {
        let harness = Harness()
        harness.suggester.answers = [.failure(.declined), .success([suggestion("wˈɪnstən")])]
        let suggestions = harness.model.pronunciationSuggestions(for: "Winston")

        suggestions.generate()
        #expect(await eventually { suggestions.phase != .loading })
        #expect(suggestions.phase == .failed(userMessage(for: PronunciationSuggestionError.declined)))
        suggestions.generate()

        #expect(suggestions.phase == .loading)
        #expect(await eventually { suggestions.phase != .loading })
        #expect(try #require(candidates(of: suggestions)).map(\.suggestion.phonemes) == ["wˈɪnstən"])
        #expect(harness.suggester.words == ["Winston", "Winston"])
    }

    @Test func noSuggestionsIsAnEmptyList() async throws {
        let harness = Harness()
        harness.suggester.answers = [.success([suggestion("  ")])]
        let suggestions = harness.model.pronunciationSuggestions(for: "Winston")

        suggestions.generate()

        #expect(await eventually { suggestions.phase != .loading })
        #expect(suggestions.phase == .loaded([]))
    }

    /// Counts the times a list read Kokoro's symbols: once for each answer it handled, right
    /// before it shows that answer or drops it as stale, in the same turn of the main actor.
    @MainActor
    private final class SymbolReads {
        var count = 0
    }

    /// A list of `word`'s suggestions from `suggester`, counting its reads of Kokoro's symbols in
    /// `reads`, so a test can tell when it has handled an answer it drops.
    private func suggestions(
        for word: String,
        from suggester: FakePronunciationSuggester,
        reads: SymbolReads
    ) -> PronunciationSuggestions {
        PronunciationSuggestions(word: word, suggester: suggester) {
            reads.count += 1
            return Set("wˈɪnstənɑ")
        }
    }

    @Test func regenerateReplacesTheRequestUnderWayWhicheverAnswersFirst() async throws {
        let suggester = FakePronunciationSuggester()
        suggester.holdsAnswers = true
        suggester.answers = [.success([suggestion("wˈɪnstən")]), .success([suggestion("wɪnstˈɑn")])]
        let reads = SymbolReads()
        let suggestions = suggestions(for: "Winston", from: suggester, reads: reads)
        suggestions.generate()
        #expect(await eventually { suggester.heldAnswers == 1 })

        suggestions.generate()

        // The first request is cancelled, but a model may answer it anyway.
        #expect(await eventually { suggester.cancelledRequests == [0] && suggester.heldAnswers == 2 })
        #expect(suggestions.phase == .loading)
        suggester.releaseAnswer(1)
        #expect(await eventually { suggestions.phase != .loading })
        #expect(try #require(candidates(of: suggestions)).map(\.suggestion.phonemes) == ["wɪnstˈɑn"])
        suggester.releaseAnswer(0)
        #expect(await eventually { reads.count == 2 })
        // Handled, and dropped.
        #expect(try #require(candidates(of: suggestions)).map(\.suggestion.phonemes) == ["wɪnstˈɑn"])
    }

    @Test func closingTheListCancelsItsRequestAndDropsTheAnswer() async throws {
        let suggester = FakePronunciationSuggester()
        suggester.holdsAnswers = true
        suggester.answers = [.success([suggestion("wˈɪnstən")])]
        let reads = SymbolReads()
        let suggestions = suggestions(for: "Winston", from: suggester, reads: reads)
        suggestions.generate()
        #expect(await eventually { suggester.heldAnswers == 1 })

        suggestions.cancel()

        #expect(await eventually { suggester.cancelledRequests == [0] })
        suggester.releaseAnswer(0)
        #expect(await eventually { reads.count == 1 })
        #expect(suggestions.phase == .loading)
    }

    @Test func usingASuggestionFillsThePronunciationsIPAAndSavesIt() async throws {
        let harness = Harness()
        let model = harness.model
        let winston = Pronunciation(word: "Winston", replacement: "wˈɪnstɑn", mode: .phonetic)
        model.pronunciations = [Pronunciation(word: "JSON", replacement: "Jason"), winston]
        harness.suggester.answers = [.success([suggestion("wˈɪnstən", "WIN-stun")])]
        let suggestions = model.pronunciationSuggestions(for: winston.word)
        suggestions.generate()
        #expect(await eventually { suggestions.phase != .loading })
        let candidate = try #require(candidates(of: suggestions)?.first)

        #expect(model.use(candidate, forPronunciation: winston.id))

        let filled = Pronunciation(id: winston.id, word: "Winston", replacement: "wˈɪnstən", mode: .phonetic)
        #expect(model.pronunciations == [Pronunciation(id: model.pronunciations[0].id, word: "JSON", replacement: "Jason"), filled])
        #expect(model.voiceLoop.pronunciations == model.pronunciations)
        #expect(harness.relaunchedModel().pronunciations == model.pronunciations)
    }

    @Test func aSuggestionWithASymbolKokoroLacksOrForAPronunciationSinceRemovedIsNotUsed() async throws {
        let harness = Harness()
        let model = harness.model
        let winston = Pronunciation(word: "Winston", replacement: "wˈɪnstɑn", mode: .phonetic)
        model.pronunciations = [winston]
        harness.suggester.answers = [.success([suggestion("wˈɪnstɑx"), suggestion("wˈɪnstən")])]
        let suggestions = model.pronunciationSuggestions(for: winston.word)
        suggestions.generate()
        #expect(await eventually { suggestions.phase != .loading })
        let candidates = try #require(candidates(of: suggestions))

        #expect(!model.use(candidates[0], forPronunciation: winston.id))
        #expect(model.pronunciations == [winston])
        model.pronunciations = []
        #expect(!model.use(candidates[1], forPronunciation: winston.id))
        #expect(model.pronunciations.isEmpty)
    }
}
