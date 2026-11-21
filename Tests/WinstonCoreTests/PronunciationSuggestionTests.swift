import Foundation
import Testing
import VoiceLoop
import VoiceLoopTestSupport
// For `PronunciationSuggestions`' own init, which takes the symbols to check against and tells
// when an answer was handled.
@testable import WinstonCore

/// The Suggest button on an IPA pronunciation in settings, and the list it opens: when it asks,
/// what the list shows, and using a suggestion.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PronunciationSuggestionTests {
    private func suggestion(_ phonemes: String, _ respelling: String = "", _ note: String = "") -> PronunciationSuggestion {
        PronunciationSuggestion(phonemes: phonemes, respelling: respelling, note: note)
    }

    /// The list's candidates, checked against the symbols Kokoro has now, once it has loaded, or
    /// nil.
    private func candidates(of suggestions: PronunciationSuggestions) -> [PronunciationCandidate]? {
        guard case .loaded = suggestions.phase else { return nil }
        return suggestions.candidates
    }

    @Test func aSuggesterThatCantRunIsNotAskedAndTheListSaysWhyForEachReason() async throws {
        let harness = Harness()
        let suggestions = harness.model.pronunciationSuggestions(for: "Winston")
        let reasons = PronunciationSuggesterAvailability.UnavailableReason.allCases
        var messages: [String] = []

        for reason in reasons {
            harness.suggester.availability = .unavailable(reason)
            suggestions.generate()
            // At once: there is nothing to wait for.
            #expect(suggestions.phase == .failed(userMessage(for: PronunciationSuggestionError.unavailable(reason))))
            if case .failed(let message) = suggestions.phase {
                messages.append(message)
            }
        }

        #expect(harness.suggester.words.isEmpty)
        // Each reason has a message of its own, and the one Adam can fix says where.
        #expect(Set(messages).count == reasons.count)
        #expect(userMessage(for: PronunciationSuggestionError.unavailable(.appleIntelligenceNotEnabled)).contains("Apple Intelligence & Siri"))
        // Once it can run, Regenerate asks.
        harness.suggester.availability = .available
        harness.suggester.answers = [.success([suggestion("wˈɪnstən")])]
        suggestions.generate()
        #expect(await eventually { suggestions.phase != .loading })
        #expect(try #require(candidates(of: suggestions)).map(\.suggestion.phonemes) == ["wˈɪnstən"])
        #expect(harness.suggester.words == ["Winston"])
    }

    @Test func theListSaysWhereTheSuggestionsComeFromInTheSuggestersWords() {
        let harness = Harness()

        #expect(harness.model.pronunciationSuggestions(for: "Winston").attribution == "Suggested by the fake suggester.")
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

    @Test func eachReasonTheSuggestionsCantPlayIsToldApart() async {
        let harness = Harness()
        let model = harness.model
        let kokoro = harness.bed.kokoro

        // A system voice: choosing a Kokoro voice would help.
        #expect(model.suggestionPlayback == .needsKokoroVoice)
        kokoro.loadBehavior = .waits
        model.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { kokoro.loads == 1 })
        // Loading: waiting would.
        #expect(model.suggestionPlayback == .waitsForVoiceModel)
        kokoro.finishLoading(succeeding: false)
        #expect(await eventually { model.voiceLoop.kokoroModelState == .failed })
        // Failed: waiting wouldn't, but retrying might.
        #expect(model.suggestionPlayback == .voiceModelFailed)
        model.kokoroModelVariant = nil
        // No Model: nothing loads until one is chosen.
        #expect(model.suggestionPlayback == .needsVoiceModel)
        kokoro.loadBehavior = .succeeds
        model.kokoroModelVariant = .soniqo5s
        #expect(await eventually { model.voiceLoop.kokoroModelState == .ready })
        #expect(model.suggestionPlayback == .plays)
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

    @Test func theSuggestionsShownFollowTheSymbolsKokoroCanSayNow() async throws {
        let harness = Harness()
        let model = harness.model
        // The loaded model's vocabulary has y, which misaki's US symbols lack.
        harness.bed.kokoro.symbols = Set("lˈybɛk")
        harness.bed.kokoro.loadBehavior = .waits
        model.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { harness.bed.kokoro.loads == 1 })
        harness.suggester.answers = [.success([suggestion("lˈybɛk")])]
        let suggestions = model.pronunciationSuggestions(for: "Lübeck")
        suggestions.generate()
        #expect(await eventually { suggestions.phase != .loading })
        // While the model loads, the fallback symbols are the ones there are.
        #expect(try #require(candidates(of: suggestions)).map(\.unknownSymbols) == [["y"]])

        harness.bed.kokoro.finishLoading(succeeding: true)
        #expect(await eventually { model.voiceLoop.kokoroModelState == .ready })

        #expect(try #require(candidates(of: suggestions)).map(\.isUsable) == [true])
        // A system voice frees the model, and the fallback symbols are back.
        model.voiceIdentifier = nil
        #expect(try #require(candidates(of: suggestions)).map(\.isUsable) == [false])
        // Checked each time, not asked again.
        #expect(harness.suggester.words == ["Lübeck"])
    }

    @Test func theSuggestionsShownAreObservableThroughTheSymbolsKokoroCanSay() async throws {
        let harness = Harness()
        let model = harness.model
        harness.bed.kokoro.symbols = Set("lˈybɛk")
        harness.suggester.answers = [.success([suggestion("lˈybɛk")])]
        let suggestions = model.pronunciationSuggestions(for: "Lübeck")
        suggestions.generate()
        #expect(await eventually { suggestions.phase != .loading })
        // What a view showing the candidates sees change.
        let usable = ValueLog { suggestions.candidates.map(\.isUsable) }

        model.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { model.voiceLoop.kokoroModelState == .ready })

        #expect(usable.values.first == [false])
        #expect(usable.values.last == [true])
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

    /// Counts the answers a list has handled, shown or dropped.
    @MainActor
    private final class HandledAnswers {
        var count = 0
    }

    /// A list of `word`'s suggestions from `suggester`, counting the answers it handles in
    /// `handled`, so a test can tell when it has dropped one, and giving up on a request after
    /// `timeout`.
    private func suggestions(
        for word: String,
        from suggester: FakePronunciationSuggester,
        handled: HandledAnswers,
        timeout: Duration = PronunciationSuggestions.defaultTimeout
    ) -> PronunciationSuggestions {
        PronunciationSuggestions(word: word, suggester: suggester, timeout: timeout) {
            Set("wˈɪnstənɑ")
        } answerHandled: {
            handled.count += 1
        }
    }

    /// On the iPhone the list's content shows, disappears and shows again as its popover becomes
    /// a sheet. Each showing starts the list, and the request the first started must carry on and
    /// its answer show: once it was cancelled, and the list loaded for good.
    @Test func aListShownAgainKeepsItsRequestAndShowsTheAnswer() async throws {
        let suggester = FakePronunciationSuggester()
        suggester.holdsAnswers = true
        suggester.answers = [.success([suggestion("wˈɪnstən")])]
        let handled = HandledAnswers()
        let suggestions = suggestions(for: "Winston", from: suggester, handled: handled)
        suggestions.start()
        #expect(await eventually { suggester.heldAnswers == 1 })

        suggestions.start()
        suggester.releaseAnswers()

        #expect(await eventually { suggestions.phase != .loading })
        #expect(try #require(candidates(of: suggestions)).map(\.suggestion.phonemes) == ["wˈɪnstən"])
        #expect(suggester.words == ["Winston"])
        #expect(suggester.cancelledRequests.isEmpty)
        // Shown again once answered, it keeps the answer rather than ask again.
        suggestions.start()
        #expect(candidates(of: suggestions) != nil)
    }

    @Test func aRequestNotAnsweredInTimeIsCancelledAndTheListSaysSo() async throws {
        let suggester = FakePronunciationSuggester()
        suggester.holdsAnswers = true
        suggester.answers = [.success([suggestion("wˈɪnstən")])]
        let handled = HandledAnswers()
        let suggestions = suggestions(for: "Winston", from: suggester, handled: handled, timeout: .milliseconds(50))

        suggestions.start()

        #expect(await eventually { suggestions.phase != .loading })
        #expect(suggestions.phase == .failed(userMessage(for: PronunciationSuggestionError.timedOut)))
        #expect(await eventually { suggester.cancelledRequests == [0] })
        // Its answer, should it come after all, is dropped.
        #expect(await eventually { suggester.heldAnswers == 1 })
        suggester.releaseAnswers()
        #expect(await eventually { handled.count == 1 })
        #expect(suggestions.phase == .failed(userMessage(for: PronunciationSuggestionError.timedOut)))
    }

    @Test func regenerateReplacesTheRequestUnderWayWhicheverAnswersFirst() async throws {
        let suggester = FakePronunciationSuggester()
        suggester.holdsAnswers = true
        suggester.answers = [.success([suggestion("wˈɪnstən")]), .success([suggestion("wɪnstˈɑn")])]
        let handled = HandledAnswers()
        let suggestions = suggestions(for: "Winston", from: suggester, handled: handled)
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
        #expect(await eventually { handled.count == 2 })
        // Handled, and dropped.
        #expect(try #require(candidates(of: suggestions)).map(\.suggestion.phonemes) == ["wɪnstˈɑn"])
    }

    @Test func regenerateDropsTheOlderAnswerWhenItComesFirst() async throws {
        let suggester = FakePronunciationSuggester()
        suggester.holdsAnswers = true
        suggester.answers = [.success([suggestion("wˈɪnstən")]), .success([suggestion("wɪnstˈɑn")])]
        let handled = HandledAnswers()
        let suggestions = suggestions(for: "Winston", from: suggester, handled: handled)
        suggestions.generate()
        #expect(await eventually { suggester.heldAnswers == 1 })
        suggestions.generate()
        #expect(await eventually { suggester.cancelledRequests == [0] && suggester.heldAnswers == 2 })

        suggester.releaseAnswer(0)

        #expect(await eventually { handled.count == 1 })
        // Handled, and dropped: the newer request is still under way.
        #expect(suggestions.phase == .loading)
        suggester.releaseAnswer(1)
        #expect(await eventually { suggestions.phase != .loading })
        #expect(try #require(candidates(of: suggestions)).map(\.suggestion.phonemes) == ["wɪnstˈɑn"])
    }

    @Test func closingTheListCancelsItsRequestAndDropsTheAnswer() async throws {
        let suggester = FakePronunciationSuggester()
        suggester.holdsAnswers = true
        suggester.answers = [.success([suggestion("wˈɪnstən")])]
        let handled = HandledAnswers()
        let suggestions = suggestions(for: "Winston", from: suggester, handled: handled)
        suggestions.generate()
        #expect(await eventually { suggester.heldAnswers == 1 })

        suggestions.cancel()

        #expect(await eventually { suggester.cancelledRequests == [0] })
        suggester.releaseAnswer(0)
        #expect(await eventually { handled.count == 1 })
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

    @Test func aSuggestionIsUsedOnlyIfKokoroCanSayItNow() async throws {
        let harness = Harness()
        let model = harness.model
        harness.bed.kokoro.symbols = Set("lˈybɛk")
        model.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { model.voiceLoop.kokoroModelState == .ready })
        let lubeck = Pronunciation(word: "Lübeck", mode: .phonetic)
        model.pronunciations = [lubeck]
        harness.suggester.answers = [.success([suggestion("lˈybɛk")])]
        let suggestions = model.pronunciationSuggestions(for: lubeck.word)
        suggestions.generate()
        #expect(await eventually { suggestions.phase != .loading })
        // Usable while the model is ready, as the list showed it.
        let candidate = try #require(candidates(of: suggestions)?.first)
        #expect(candidate.isUsable)

        // Freed before Use: the fallback symbols lack y.
        model.voiceIdentifier = nil

        #expect(!model.use(candidate, forPronunciation: lubeck.id))
        #expect(model.pronunciations == [lubeck])
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
