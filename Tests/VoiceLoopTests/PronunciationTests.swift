import Foundation
import Testing
@testable import VoiceLoop

/// The pronunciations in settings: words said differently, by every voice.
@Suite struct PronunciationTests {
    private func say(_ text: String, with pronunciations: [(String, String)]) -> String {
        PronunciationReplacer(pronunciations.map { Pronunciation(word: $0.0, replacement: $0.1) }).replaced(in: text)
    }

    @Test func aWordIsReplacedOnlyWithTheSameCaseAndOnlyWhole() {
        let json = [("JSON", "Jason")]
        #expect(say("Use JSON, not json or JSONs.", with: json) == "Use Jason, not json or JSONs.")
        #expect(say("JSON's keys", with: json) == "Jason's keys")
        #expect(say("v2 and v20", with: [("v2", "version two")]) == "version two and v20")
    }

    @Test func aWordCanBeSeveralWordsOrHavePunctuation() {
        #expect(say("New York City and New York", with: [("New York", "NY"), ("New York City", "the city")])
            == "the city and NY")
        #expect(say("I write C++ daily.", with: [("C++", "C plus plus")]) == "I write C plus plus daily.")
    }

    @Test func aReplacementIsNotLookedThroughForWords() {
        #expect(say("cat and dog", with: [("cat", "dog"), ("dog", "cat")]) == "dog and cat")
    }

    @Test func wordsAndReplacementsAreTrimmedAndBlankOnesSkipped() {
        let pronunciations = [(" API ", " A P I "), ("", "nothing"), ("foo", "  ")]
        #expect(say("API foo", with: pronunciations) == "A P I foo")
    }

    @Test func ofTwoWithTheSameWordTheFirstCounts() {
        #expect(say("Kokoro", with: [("Kokoro", "Ko ko ro"), ("Kokoro", "Coco")]) == "Ko ko ro")
    }

    @Test func withoutPronunciationsTheTextIsUnchanged() {
        #expect(say("Nothing to do here.", with: []) == "Nothing to do here.")
    }
}

/// Saved pronunciations: each has a mode, and one saved before there were modes is a respelling.
@Suite struct PronunciationModeTests {
    @Test func oneSavedWithoutAModeIsARespelling() throws {
        let id = UUID()
        let saved = Data(#"[{"id": "\#(id.uuidString)", "word": "JSON", "replacement": "Jason"}]"#.utf8)

        let pronunciations = try JSONDecoder().decode([Pronunciation].self, from: saved)

        #expect(pronunciations == [Pronunciation(id: id, word: "JSON", replacement: "Jason", mode: .respelling)])
    }

    @Test func theModeIsSavedAndRead() throws {
        let pronunciations = [
            Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic),
            Pronunciation(word: "JSON", replacement: "Jason", mode: .respelling),
        ]

        let read = try JSONDecoder().decode([Pronunciation].self, from: JSONEncoder().encode(pronunciations))

        #expect(read == pronunciations)
    }

    @Test func aNewPronunciationIsARespelling() {
        #expect(Pronunciation().mode == .respelling)
    }
}

/// Phonetic pronunciations: each word is replaced by a placeholder that Kokoro is given the
/// phonemes for, and that the system voices get back as the word.
@Suite struct PhoneticPronunciationTests {
    /// `text` as Kokoro gets it, with `pronunciations`' placeholders recorded in `placeholders`.
    private func say(_ text: String, with pronunciations: [Pronunciation], placeholders: inout PhoneticPlaceholders) -> String {
        placeholders.update(with: pronunciations)
        return PronunciationReplacer(pronunciations, placeholders: placeholders).replaced(in: text)
    }

    @Test func aPhoneticWordBecomesItsPlaceholderOnlyWithTheSameCaseAndOnlyWhole() throws {
        let kokoro = Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic)
        var placeholders = PhoneticPlaceholders()

        let said = say("Kokoro, not kokoro or Kokoros. Kokoro's voice.", with: [kokoro], placeholders: &placeholders)

        let placeholder = try #require(placeholders.placeholder(for: kokoro.id))
        #expect(said == "\(placeholder), not kokoro or Kokoros. \(placeholder)'s voice.")
        #expect(placeholders.phonemes(in: said) == [placeholder: "kˈOkəɹO"])
        #expect(placeholders.written(said) == "Kokoro, not kokoro or Kokoros. Kokoro's voice.")
    }

    @Test func respellingsAndPhoneticWordsMatchTogetherLongestFirst() throws {
        let city = Pronunciation(word: "New York City", replacement: "nˈu jˈɔɹk sˈɪɾi", mode: .phonetic)
        let state = Pronunciation(word: "New York", replacement: "NY")
        var placeholders = PhoneticPlaceholders()

        let said = say("New York City and New York", with: [state, city], placeholders: &placeholders)

        let placeholder = try #require(placeholders.placeholder(for: city.id))
        #expect(said == "\(placeholder) and NY")
    }

    @Test func ofTwoWithTheSameWordTheFirstCountsWhateverItsMode() throws {
        let phonetic = Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic)
        let respelling = Pronunciation(word: "Kokoro", replacement: "Coco")
        var placeholders = PhoneticPlaceholders()

        let phoneticFirst = say("Kokoro", with: [phonetic, respelling], placeholders: &placeholders)
        let respellingFirst = say("Kokoro", with: [respelling, phonetic], placeholders: &placeholders)

        #expect(phoneticFirst == placeholders.placeholder(for: phonetic.id))
        #expect(respellingFirst == "Coco")
    }

    @Test func aPhoneticWordOrPhonemesLeftBlankIsSkipped() {
        let pronunciations = [
            Pronunciation(word: "Kokoro", replacement: "  ", mode: .phonetic),
            Pronunciation(word: " ", replacement: "kˈOkəɹO", mode: .phonetic),
        ]
        var placeholders = PhoneticPlaceholders()

        #expect(say("Kokoro", with: pronunciations, placeholders: &placeholders) == "Kokoro")
        #expect(pronunciations.allSatisfy { placeholders.placeholder(for: $0.id) == nil })
    }

    @Test func eachPronunciationKeepsItsPlaceholderAndItsLatestWordAndPhonemes() throws {
        var kokoro = Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic)
        let other = Pronunciation(word: "Winston", replacement: "wˈɪnstən", mode: .phonetic)
        var placeholders = PhoneticPlaceholders()
        placeholders.update(with: [kokoro, other])
        let placeholder = try #require(placeholders.placeholder(for: kokoro.id))
        #expect(placeholders.placeholder(for: other.id) != placeholder)

        kokoro.word = "Kokoro TTS"
        kokoro.replacement = "kˈOkəɹO tˌitˌiˈɛs"
        placeholders.update(with: [other, kokoro])

        #expect(placeholders.placeholder(for: kokoro.id) == placeholder)
        #expect(placeholders.phonemes(in: placeholder) == [placeholder: "kˈOkəɹO tˌitˌiˈɛs"])
        #expect(placeholders.written(placeholder) == "Kokoro TTS")
    }

    @Test func aRemovedPronunciationsPlaceholderStillSaysItsWord() throws {
        let kokoro = Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic)
        var placeholders = PhoneticPlaceholders()
        let queued = say("Kokoro.", with: [kokoro], placeholders: &placeholders)

        placeholders.update(with: [])

        let placeholder = try #require(placeholders.placeholder(for: kokoro.id))
        #expect(placeholders.phonemes(in: queued) == [placeholder: "kˈOkəɹO"])
        #expect(placeholders.written(queued) == "Kokoro.")
    }

    @Test func thePreviewPlaceholderSaysTheLatestPreviewsWordAndPhonemes() {
        let preview = PhoneticPlaceholders.preview
        var placeholders = PhoneticPlaceholders()

        placeholders.setPreview(word: "Kokoro", phonemes: "kˈOkəɹO")
        placeholders.setPreview(word: "Kokoro", phonemes: "kəkˈɔɹO")

        #expect(placeholders.phonemes(in: preview) == [preview: "kəkˈɔɹO"])
        #expect(placeholders.written(preview) == "Kokoro")
    }

    @Test func placeholdersAreDistinctAndLowercaseASCIILetters() {
        let placeholders = (0..<2_000).map(PhoneticPlaceholders.placeholder(number:))

        #expect(Set(placeholders).count == placeholders.count)
        #expect(placeholders.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isLowercase } })
        #expect(PhoneticPlaceholders.placeholder(number: 0) == "zqxaq")
        #expect(PhoneticPlaceholders.placeholder(number: 26) == "zqxaaq")
    }

    @Test func textWithoutPlaceholdersIsLeftAlone() {
        var placeholders = PhoneticPlaceholders()
        placeholders.update(with: [Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic)])

        #expect(placeholders.phonemes(in: "Kokoro said zqx and q.") == [:])
        #expect(placeholders.written("Kokoro said zqx and q.") == "Kokoro said zqx and q.")
    }

    @Test func placeholdersComeThroughKokorosNumbersAndAcronymsWhole() throws {
        let kokoro = Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic)
        var placeholders = PhoneticPlaceholders()
        let said = say("Kokoro-5 and Kokoro's API, 3rd Kokoro (Kokoro).", with: [kokoro], placeholders: &placeholders)
        let placeholder = try #require(placeholders.placeholder(for: kokoro.id))

        let spoken = KokoroAcronyms(dictionaryWords: ["and"]).spelledOut(KokoroNumbers().spelledOut(said))

        let p = placeholder
        #expect(spoken == "\(p) five and \(p)'s eh P eye, third \(p) (\(p)).")
        #expect(placeholders.phonemes(in: spoken) == [placeholder: "kˈOkəɹO"])
    }
}
