import Testing
@testable import VoiceLoop

/// What every voice is given for compound words written with a capital starting each word.
@Suite struct CompoundWordsTests {
    private func say(_ text: String) -> String {
        CompoundWords.split(text)
    }

    @Test func aCompoundIsSplitIntoItsWords() {
        #expect(say("CorpusGraph") == "Corpus Graph")
        #expect(say("MuseApplication") == "Muse Application")
        #expect(say("TheCorpusGraphView") == "The Corpus Graph View")
    }

    @Test func anAcronymInACompoundStaysWhole() {
        #expect(say("URLSession") == "URL Session")
        #expect(say("JSONDecoder") == "JSON Decoder")
        #expect(say("SwiftUI") == "Swift UI")
        #expect(say("MyURL") == "My URL")
        #expect(say("XCTAssertEqual") == "XCT Assert Equal")
        #expect(say("UIViewController") == "UI View Controller")
    }

    @Test func anSThatEndsTheWordMakesAnAcronymPlural() {
        #expect(say("APIs and URLs") == "APIs and URLs")
        #expect(say("MyAPIs") == "My APIs")
        // Not at the end, it starts a word.
        #expect(say("UISwitch") == "UI Switch")
    }

    @Test func aCapitalAfterADigitStartsAWord() {
        #expect(say("Base64Encoder") == "Base64 Encoder")
        #expect(say("MP3Player") == "MP3 Player")
        // Capitals alone after a digit don't.
        #expect(say("Vector3D") == "Vector3D")
        #expect(say("Win32API") == "Win32API")
    }

    @Test func compoundsAreSplitInsideAMessage() {
        #expect(
            say("Open CorpusGraph's file, then MuseApplication.swift (see URLSession).")
                == "Open Corpus Graph's file, then Muse Application.swift (see URL Session)."
        )
    }

    @Test func otherWordsStay() {
        let text = "Hello there, NASA and the API. It's DONE."
        #expect(say(text) == text)
    }

    @Test func aWordThatStartsLowercaseStays() {
        let text = "iPhone, macOS, eBay and viewDidLoad"
        #expect(say(text) == text)
    }

    @Test func aWordThatWouldLeaveALetterByItselfStays() {
        let text = "a PhD, 3 GHz, OAuth and LaTeX"
        #expect(say(text) == text)
    }

    @Test func aWordWithALetterOutsideASCIIStays() {
        #expect(say("CaféBar") == "CaféBar")
    }

    @Test func phoneticPlaceholdersStay() {
        // As a message holds one that starts a sentence: "Zqxaq".
        let placeholder = PhoneticPlaceholders.placeholder(number: 0)
        let text = placeholder.prefix(1).uppercased() + placeholder.dropFirst() + " opens."
        #expect(say(text) == text)
    }
}
