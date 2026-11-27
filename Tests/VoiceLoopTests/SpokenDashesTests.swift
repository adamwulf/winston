import Testing
@testable import VoiceLoop

/// What every voice is given for hyphens and dashes.
@Suite struct SpokenDashesTests {
    @Test func hyphensEnDashesAndEmDashesAreSpaces() {
        #expect(SpokenDashes.spaced("a well-known fix") == "a well known fix")
        #expect(SpokenDashes.spaced("pages a–z") == "pages a z")
        #expect(SpokenDashes.spaced("now—or later") == "now or later")
        #expect(SpokenDashes.spaced("wait - what") == "wait   what")
    }

    @Test func aHyphenOrEnDashNextToANumberStays() {
        #expect(SpokenDashes.spaced("-5 to 1-5, call 555-1234") == "-5 to 1-5, call 555-1234")
        #expect(SpokenDashes.spaced("COVID-19 and pages 3–7") == "COVID-19 and pages 3–7")
        #expect(SpokenDashes.spaced("-$20, $80k–$120k, -.5, '80s-'90s") == "-$20, $80k–$120k, -.5, '80s-'90s")
        #expect(SpokenDashes.spaced("2020—2021") == "2020 2021")
        // A sign with no digit after it starts no number.
        #expect(SpokenDashes.spaced("pay-$ later, it-.") == "pay $ later, it .")
    }

    @Test func dashesTogetherAreSpacesEvenNextToANumber() {
        #expect(SpokenDashes.spaced("a while--3 hours, the total--$45") == "a while  3 hours, the total  $45")
    }
}
