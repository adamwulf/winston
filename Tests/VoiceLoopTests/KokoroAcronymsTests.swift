import Testing
@testable import VoiceLoop

/// What Kokoro is given for text with acronyms in it: letters it says by name.
@Suite struct KokoroAcronymsTests {
    /// A few of the words in KokoroTTS's dictionary, as `LiveKokoro.dictionaryWords()` returns
    /// them: lowercased. "apis" (bees) and "id" are there too.
    private let acronyms = KokoroAcronyms(dictionaryWords: [
        "the", "is", "it", "not", "very", "important", "done", "test", "stop", "run", "nasa", "ram", "sql",
        "ok", "us", "ai", "isn't", "don't", "cafe", "apis", "id", "am", "os", "disk",
    ])

    private func say(_ text: String) -> String {
        acronyms.spelledOut(text)
    }

    @Test func anAcronymTheDictionaryDoesNotHaveIsSpelledOut() {
        #expect(say("Call the API.") == "Call the eh P eye.")
        #expect(say("Open the URL (HTTPS only)") == "Open the U R L (H T T P S only)")
        #expect(say("GPU, LLM and TTS") == "G P U, L L M and T T S")
    }

    @Test func everyLetterIsWrittenAsItsName() {
        #expect(say("ABCDEFGHIJKLMNOPQRSTUVWXYZ") == "eh B C D E F G H eye J K L M N O P Q R S T U V W X Y Z")
    }

    @Test func anSOrApostropheSAfterAnAcronymMakesItPlural() {
        #expect(say("Two PRs and three APIs") == "Two P Rs and three eh P eyes")
        #expect(say("the API's docs") == "the eh P eyes docs")
        #expect(say("the API’s docs") == "the eh P eyes docs")
        #expect(say("GPUs, URLs") == "G P ewes, U R ells")
    }

    @Test func everyLettersPluralIsWrittenAsItsNameWithAnS() {
        let plurals = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { say("Q\($0)s") }
        #expect(plurals == [
            "Q ehs", "Q bees", "Q sees", "Q dees", "Q ease", "Q effs", "Q gees", "Q aitches", "Q eyes",
            "Q jays", "Q kays", "Q ells", "Q ems", "Q ens", "Q ohs", "Q pees", "Q cues", "Q Rs",
            "Q esses", "Q tees", "Q ewes", "Q vees", "Q double ewes", "Q exes", "Q wise", "Q zees",
        ])
    }

    @Test func anAcronymTheDictionaryHasAsAWordStays() {
        #expect(say("NASA uses RAM and SQL") == "NASA uses RAM and SQL")
        #expect(say("OK, the AI is done.") == "OK, the AI is done.")
        #expect(say("OKs") == "OKs")
    }

    @Test func aWordInCapitalsForEmphasisStays() {
        #expect(say("This is VERY IMPORTANT. Do NOT stop.") == "This is VERY IMPORTANT. Do NOT stop.")
        #expect(say("IT IS US") == "IT IS US")
    }

    @Test func aWordInCapitalsWithAnEndingTheDictionaryTakesOffStays() {
        #expect(say("TESTS TESTED TESTING") == "TESTS TESTED TESTING")
        #expect(say("STOPPED STOPPING RUNNING") == "STOPPED STOPPING RUNNING")
    }

    @Test func aFewAcronymsTheDictionaryHasAsOtherWordsAreSpelledOutAnyway() {
        #expect(say("the chat ID and their IDs") == "the chat eye D and their eye dees")
        #expect(say("at ten AM on any OS") == "at ten eh M on any O S")
    }

    @Test func anAcronymInsideAWordIsSpelledOutApartFromTheRest() {
        #expect(say("SwiftUI") == "Swift U eye")
        #expect(say("iOS and macOS") == "i O S and mac O S")
        // The run's last capital starts the next word.
        #expect(say("URLSession") == "U R L Session")
        #expect(say("XCTest") == "X C Test")
        #expect(say("OAuth") == "O Auth")
        // A known acronym stays, but apart from the word after it.
        #expect(say("RAMDisk") == "RAM Disk")
    }

    @Test func singleCapitalsAndOrdinaryWordsStay() {
        #expect(say("A plan, plan B, and I think so.") == "A plan, plan B, and I think so.")
        #expect(say("VoiceLoop on GitHub, a PhD") == "VoiceLoop on GitHub, a PhD")
    }

    @Test func aWordWithAnyOtherApostropheStays() {
        #expect(say("IT ISN'T DONE") == "IT ISN'T DONE")
        #expect(say("DON’T") == "DON’T")
        #expect(say("O'BRIEN") == "O'BRIEN")
    }

    @Test func aWordWithALetterOutsideASCIIStays() {
        #expect(say("CAFÉ") == "CAFÉ")
    }

    @Test func withoutTheDictionaryNothingIsSpelledOut() {
        #expect(KokoroAcronyms(dictionaryWords: []).spelledOut("The API is NOT up.") == "The API is NOT up.")
    }
}
