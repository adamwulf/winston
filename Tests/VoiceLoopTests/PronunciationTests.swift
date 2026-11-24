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

/// Pronunciations whose word matches whatever its case, beside ones that match only with the same
/// case.
@Suite struct CaselessPronunciationTests {
    private func say(_ text: String, with pronunciations: [Pronunciation]) -> String {
        PronunciationReplacer(pronunciations).replaced(in: text)
    }

    @Test func aWordThatDoesntMatchCaseIsReplacedInAnyCaseButStillOnlyWhole() {
        let json = Pronunciation(word: "JSON", replacement: "Jason", matchesCase: false)

        #expect(say("Use JSON, json or Json, not JSONs.", with: [json]) == "Use Jason, Jason or Jason, not JSONs.")
        #expect(say("json's keys", with: [json]) == "Jason's keys")
    }

    @Test func aRespellingThatDoesntMatchCaseStartsWithACapitalWhereItsWordDoesSoSentencesAreStillFound() {
        let kubectl = Pronunciation(word: "kubectl", replacement: "cube control", matchesCase: false)
        let api = Pronunciation(word: "api", replacement: "A P I", matchesCase: false)

        let said = say("Install it first. Kubectl runs the cluster, and kubectl calls the api.", with: [kubectl, api])

        #expect(said == "Install it first. Cube control runs the cluster, and cube control calls the A P I.")
        #expect(KokoroText.sentences(in: said) == ["Install it first.", "Cube control runs the cluster, and cube control calls the A P I."])
        // One that matches case is said as written.
        let exact = Pronunciation(word: "Kubectl", replacement: "cube control")
        #expect(say("First. Kubectl runs.", with: [exact]) == "First. cube control runs.")
    }

    @Test func eachWordMatchesCaseOrNotOnItsOwn() {
        let city = Pronunciation(word: "New York City", replacement: "the city")
        let state = Pronunciation(word: "New York", replacement: "NY", matchesCase: false)

        // The longer word matches only with its case, so in lowercase the shorter one matches.
        #expect(say("New York City, new york city", with: [city, state]) == "the city, NY city")
    }

    @Test func ofTwoThatMatchTheSameTextTheFirstCounts() {
        let exact = Pronunciation(word: "API", replacement: "A P I")
        let caseless = Pronunciation(word: "api", replacement: "app ee", matchesCase: false)

        // The one that matches only "API" first: the other still matches the other cases.
        #expect(say("API, api, Api", with: [exact, caseless]) == "A P I, app ee, App ee")
        // The one that matches every case first: the other never counts, nor does another that
        // matches every case.
        let otherCaseless = Pronunciation(word: "Api", replacement: "ap ee", matchesCase: false)
        #expect(say("API, api, Api", with: [caseless, exact, otherCaseless]) == "App ee, app ee, App ee")
    }
}

/// Saved pronunciations: each has a mode and whether it matches case. One saved before there were
/// modes is a respelling, and one saved before the choice of case matches case.
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

    @Test func aNewOrSavedBeforeTheChoicePronunciationMatchesCase() throws {
        let saved = Data(#"[{"id": "\#(UUID().uuidString)", "word": "JSON", "replacement": "Jason", "mode": "respelling"}]"#.utf8)

        let pronunciations = try JSONDecoder().decode([Pronunciation].self, from: saved)

        #expect(pronunciations.map(\.matchesCase) == [true])
        #expect(Pronunciation().matchesCase)
    }

    @Test func whetherItMatchesCaseIsSavedAndRead() throws {
        let pronunciations = [
            Pronunciation(word: "JSON", replacement: "Jason", matchesCase: false),
            Pronunciation(word: "API", replacement: "A P I", matchesCase: true),
        ]

        let read = try JSONDecoder().decode([Pronunciation].self, from: JSONEncoder().encode(pronunciations))

        #expect(read == pronunciations)
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

    @Test func aPhoneticWordThatDoesntMatchCaseTakesItsCapitalFromTheText() {
        let kokoro = Pronunciation(word: "kokoro", replacement: "kˈOkəɹO", mode: .phonetic, matchesCase: false)
        let ios = Pronunciation(word: "IOS", replacement: "ˌIˌOˈɛs", mode: .phonetic, matchesCase: false)
        var placeholders = PhoneticPlaceholders()

        let said = say("Not ios. Kokoro, KOKORO and kokoro on iOS.", with: [kokoro, ios], placeholders: &placeholders)

        #expect(said == "Not \(p(1)). \(capitalP(0)), \(capitalP(0)) and \(p(0)) on \(p(1)).")
        #expect(KokoroText.sentences(in: said) == ["Not \(p(1)).", "\(capitalP(0)), \(capitalP(0)) and \(p(0)) on \(p(1))."])
        #expect(placeholders.phonemes(in: said) == [p(0): "kˈOkəɹO", p(1): "ˌIˌOˈɛs"])
        // A system voice says each as its pronunciation has it.
        #expect(placeholders.written(said) == "Not IOS. kokoro, kokoro and kokoro on IOS.")
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

    @Test func sentencePunctuationThatEndsAWordStaysAfterItsPlaceholdersWhereItEndsASentence() {
        // Placeholders 0 stand for all of "Yahoo!"; 1 keep its "!" after them.
        let yahoo = Pronunciation(word: "Yahoo!", replacement: "jˈɑhu", mode: .phonetic)
        var placeholders = PhoneticPlaceholders()

        let said = say("I used Yahoo! Then I switched. Yahoo!!", with: [yahoo], placeholders: &placeholders)

        // The second ends no sentence itself: the sentence goes on to the second "!".
        #expect(said == "I used \(capitalP(1))! Then I switched. \(capitalP(0))!")
        #expect(KokoroText.sentences(in: said) == ["I used \(capitalP(1))!", "Then I switched.", "\(capitalP(0))!"])
        #expect(placeholders.phonemes(in: said) == [p(0): "jˈɑhu", p(1): "jˈɑhu"])
        // Each "!" said once.
        #expect(placeholders.written(said) == "I used Yahoo! Then I switched. Yahoo!!")
    }

    @Test func sentencePunctuationThatEndsAWordButNoSentenceIsPartOfItsPlaceholders() {
        let mister = Pronunciation(word: "Mr.", replacement: "mˈɪstəɹ", mode: .phonetic)
        var placeholders = PhoneticPlaceholders()
        let text = "Mr. Smith paid 3.50 for it."
        #expect(KokoroText.sentences(in: text) == [text])

        let said = say(text, with: [mister], placeholders: &placeholders)

        #expect(said == "\(capitalP(0)) Smith paid 3.50 for it.")
        #expect(KokoroText.sentences(in: said) == [said])
        #expect(placeholders.phonemes(in: said) == [p(0): "mˈɪstəɹ"])
        #expect(placeholders.written(said) == text)
    }

    @Test(arguments: [
        ("She shouted “Yahoo!” Then she left.", "She shouted “", "” Then she left."),
        ("She shouted \"Yahoo!\" Then she left.", "She shouted \"", "\" Then she left."),
        ("(I used Yahoo!) Then I switched.", "(I used ", ") Then I switched."),
    ])
    func sentencePunctuationStaysAfterThePlaceholdersWhereTheSentenceEndsAfterAClosingQuoteOrBracket(
        text: String,
        before: String,
        after: String
    ) {
        // Placeholders 0 stand for all of "Yahoo!"; 1 keep its "!" after them.
        let yahoo = Pronunciation(word: "Yahoo!", replacement: "jˈɑhu", mode: .phonetic)
        var placeholders = PhoneticPlaceholders()
        #expect(KokoroText.sentences(in: text).count == 2)

        let said = say(text, with: [yahoo], placeholders: &placeholders)

        #expect(said == before + capitalP(1) + "!" + after)
        // The first sentence ends after the closing quote or bracket, as it did.
        let firstSentence = before + capitalP(1) + "!" + String(after.prefix(1))
        #expect(KokoroText.sentences(in: said) == [firstSentence, String(after.dropFirst(2))])
        #expect(placeholders.written(said) == text)
    }

    @Test func noLetterOrDigitEverTouchesAPlaceholder() {
        let clap = Pronunciation(word: "👏", replacement: "klˈæp", mode: .phonetic)
        let thumbs = Pronunciation(word: "👍", replacement: "thumbs up")
        let ten = Pronunciation(word: "🔟", replacement: "10")
        var placeholders = PhoneticPlaceholders()

        let said = say("👏👏 👍👏🔟 (👏)", with: [clap, thumbs, ten], placeholders: &placeholders)

        // A space where a placeholder would touch another, or a respelling's letter or digit.
        #expect(said == "\(p(0)) \(p(0)) thumbs up \(p(0)) 10 (\(p(0)))")
        #expect(placeholders.phonemes(in: said) == [p(0): "klˈæp"])
        #expect(placeholders.written(said) == "👏 👏 thumbs up 👏 10 (👏)")
        // Respellings alone are as they were.
        #expect(say("👍👍🔟", with: [thumbs, ten], placeholders: &placeholders) == "thumbs upthumbs up10")
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
        #expect(placeholders.text(for: "Kokoro", phonemes: "kˈOkəɹO", keepingPunctuation: false) == capitalP(0))
        #expect(placeholders.text(for: "Kokoro", phonemes: "kˈOkəɹO", keepingPunctuation: true) == capitalP(0))
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
