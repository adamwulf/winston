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
