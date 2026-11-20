import Foundation
import Testing
@testable import VoiceLoop

/// Respellings, the pronunciations in settings said by every voice: other text in a word's place.
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

/// The placeholder numbered `number`, in lowercase, as Kokoro is given it: the first one given
/// out is 0.
private func p(_ number: Int) -> String {
    PhoneticPlaceholders.placeholder(number: number)
}

/// The placeholder numbered `number` as a message holds it for a word that starts with a capital.
private func capitalP(_ number: Int) -> String {
    let placeholder = p(number)
    return placeholder.prefix(1).uppercased() + placeholder.dropFirst()
}

/// Phonetic pronunciations: each word is replaced by placeholders that Kokoro is given the
/// phonemes for, and that the system voices get back as the word.
@Suite struct PhoneticPronunciationTests {
    /// `text` as Kokoro gets it, with `pronunciations`' placeholders added to `placeholders`.
    private func say(_ text: String, with pronunciations: [Pronunciation], placeholders: inout PhoneticPlaceholders) -> String {
        placeholders.add(pronunciations)
        return PronunciationReplacer(pronunciations, placeholders: placeholders).replaced(in: text)
    }

    @Test func aPhoneticWordBecomesItsPlaceholderOnlyWithTheSameCaseAndOnlyWhole() {
        let kokoro = Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic)
        var placeholders = PhoneticPlaceholders()

        let said = say("Kokoro, not kokoro or Kokoros. Kokoro's voice.", with: [kokoro], placeholders: &placeholders)

        #expect(said == "\(capitalP(0)), not kokoro or Kokoros. \(capitalP(0))'s voice.")
        #expect(placeholders.phonemes(in: said) == [p(0): "kˈOkəɹO"])
        #expect(placeholders.written(said) == "Kokoro, not kokoro or Kokoros. Kokoro's voice.")
    }

    @Test func aPlaceholderStartsWithACapitalOnlyWhereItsWordDoesSoSentencesAreStillFound() {
        let kokoro = Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic)
        let ios = Pronunciation(word: "iOS", replacement: "ˌIˌOˈɛs", mode: .phonetic)
        var placeholders = PhoneticPlaceholders()

        let said = say("Not iOS. Kokoro is next.", with: [kokoro, ios], placeholders: &placeholders)

        #expect(said == "Not \(p(1)). \(capitalP(0)) is next.")
        #expect(KokoroText.sentences(in: said) == ["Not \(p(1)).", "\(capitalP(0)) is next."])
        #expect(placeholders.phonemes(in: said) == [p(0): "kˈOkəɹO", p(1): "ˌIˌOˈɛs"])
        #expect(placeholders.written(said) == "Not iOS. Kokoro is next.")
    }

    @Test func eachPhonemeWordHasAPlaceholderOfItsOwnAndASystemVoiceGetsTheWordOnce() {
        let city = Pronunciation(word: "New York City", replacement: "nˈu  jˈɔɹk sˈɪɾi", mode: .phonetic)
        var placeholders = PhoneticPlaceholders()

        let said = say("I love New York City's food.", with: [city], placeholders: &placeholders)

        // Only the first takes the capital. KokoroTTS can cut a long sentence between them.
        #expect(said == "I love \(capitalP(0)) \(p(1)) \(p(2))'s food.")
        #expect(placeholders.phonemes(in: said) == [p(0): "nˈu", p(1): "jˈɔɹk", p(2): "sˈɪɾi"])
        #expect(placeholders.written(said) == "I love New York City's food.")
    }

    @Test func sentencePunctuationThatEndsAWordStaysAfterItsPlaceholdersAndIsSaidOnce() {
        let yahoo = Pronunciation(word: "Yahoo!", replacement: "jˈɑhu", mode: .phonetic)
        var placeholders = PhoneticPlaceholders()

        let said = say("I used Yahoo! Then I switched. Yahoo!!", with: [yahoo], placeholders: &placeholders)

        #expect(said == "I used \(capitalP(0))! Then I switched. \(capitalP(0))!!")
        #expect(KokoroText.sentences(in: said) == ["I used \(capitalP(0))!", "Then I switched.", "\(capitalP(0))!!"])
        #expect(placeholders.phonemes(in: said) == [p(0): "jˈɑhu"])
        #expect(placeholders.written(said) == "I used Yahoo! Then I switched. Yahoo!!")
    }

    @Test func respellingsAndPhoneticWordsMatchTogetherLongestFirst() {
        let city = Pronunciation(word: "New York City", replacement: "nˈu jˈɔɹk sˈɪɾi", mode: .phonetic)
        let state = Pronunciation(word: "New York", replacement: "NY")
        var placeholders = PhoneticPlaceholders()

        let said = say("New York City and New York", with: [state, city], placeholders: &placeholders)

        #expect(said == "\(capitalP(0)) \(p(1)) \(p(2)) and NY")
    }

    @Test func ofTwoWithTheSameWordTheFirstCountsWhateverItsMode() {
        let phonetic = Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic)
        let respelling = Pronunciation(word: "Kokoro", replacement: "Coco")
        var placeholders = PhoneticPlaceholders()

        let phoneticFirst = say("Kokoro", with: [phonetic, respelling], placeholders: &placeholders)
        let respellingFirst = say("Kokoro", with: [respelling, phonetic], placeholders: &placeholders)

        #expect(phoneticFirst == capitalP(0))
        #expect(respellingFirst == "Coco")
    }

    @Test func aPhoneticWordOrPhonemesLeftBlankIsSkipped() {
        let pronunciations = [
            Pronunciation(word: "Kokoro", replacement: "  ", mode: .phonetic),
            Pronunciation(word: " ", replacement: "kˈOkəɹO", mode: .phonetic),
        ]
        var placeholders = PhoneticPlaceholders()

        #expect(say("Kokoro", with: pronunciations, placeholders: &placeholders) == "Kokoro")
        #expect(placeholders.phonemes(in: p(0)) == [:])
    }

    @Test func queuedTextKeepsTheWordAndPhonemesItWasQueuedWith() {
        var kokoro = Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic)
        var placeholders = PhoneticPlaceholders()
        let queued = say("Kokoro.", with: [kokoro], placeholders: &placeholders)

        kokoro.word = "Coco"
        let renamed = say("Coco.", with: [kokoro], placeholders: &placeholders)
        kokoro.replacement = "kˈOkO"
        let changed = say("Coco.", with: [kokoro], placeholders: &placeholders)
        placeholders.add([])

        #expect([queued, renamed, changed] == ["\(capitalP(0)).", "\(capitalP(1)).", "\(capitalP(2))."])
        #expect(placeholders.phonemes(in: queued) == [p(0): "kˈOkəɹO"])
        #expect(placeholders.written(queued) == "Kokoro.")
        #expect(placeholders.phonemes(in: renamed) == [p(1): "kˈOkəɹO"])
        #expect(placeholders.written(renamed) == "Coco.")
        #expect(placeholders.phonemes(in: changed) == [p(2): "kˈOkO"])
    }

    @Test func theSameWordAndPhonemesKeepTheirPlaceholdersWhereverTheyComeFrom() {
        var placeholders = PhoneticPlaceholders()
        placeholders.add([
            Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic),
            Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic),
        ])

        // A preview of the same, and of other phonemes, such as a suggestion being tried.
        let same = placeholders.add(word: "Kokoro", phonemes: "kˈOkəɹO")
        let other = placeholders.add(word: "Kokoro", phonemes: "kəkˈɔɹO")

        #expect(same == capitalP(0))
        #expect(other == capitalP(1))
        #expect(placeholders.text(for: "Kokoro", phonemes: "kˈOkəɹO") == capitalP(0))
    }

    @Test func aPlaceholderAwayFromItsGroupIsNeverSaid() {
        var placeholders = PhoneticPlaceholders()
        placeholders.add(word: "New York City", phonemes: "nˈu jˈɔɹk sˈɪɾi")

        #expect(placeholders.written("\(p(1)) \(p(2)) here") == "here")
        #expect(placeholders.written("\(capitalP(0)) here") == "New York City here")
        #expect(placeholders.written("\(capitalP(0)) \(p(2)) here") == "New York City here")
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
        placeholders.add([Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic)])

        #expect(placeholders.phonemes(in: "Kokoro said zqx and  q.") == [:])
        #expect(placeholders.written("Kokoro said zqx and  q.") == "Kokoro said zqx and  q.")
    }

    @Test func placeholdersComeThroughKokorosNumbersAndAcronymsWhole() {
        let kokoro = Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic)
        let city = Pronunciation(word: "New York City", replacement: "nˈu jˈɔɹk sˈɪɾi", mode: .phonetic)
        var placeholders = PhoneticPlaceholders()
        let said = say(
            "Kokoro-5 and Kokoro's API, 3rd Kokoro (Kokoro) in New York City-2.",
            with: [kokoro, city],
            placeholders: &placeholders
        )

        let spoken = KokoroAcronyms(dictionaryWords: ["and"]).spelledOut(KokoroNumbers().spelledOut(said))

        let k = capitalP(0)
        #expect(spoken == "\(k) five and \(k)'s eh P eye, third \(k) (\(k)) in \(capitalP(1)) \(p(2)) \(p(3)) two.")
        #expect(placeholders.phonemes(in: spoken) == [p(0): "kˈOkəɹO", p(1): "nˈu", p(2): "jˈɔɹk", p(3): "sˈɪɾi"])
    }
}
