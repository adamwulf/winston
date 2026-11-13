import Testing
@testable import VoiceLoop

/// What Kokoro is given for text with numbers in it: words it can pronounce.
@Suite struct KokoroNumbersTests {
    private let numbers = KokoroNumbers()

    private func say(_ text: String) -> String {
        numbers.spelledOut(text)
    }

    @Test func integersWithAndWithoutThousandsSeparators() {
        #expect(say("I found 3 bugs.") == "I found three bugs.")
        #expect(say("0") == "zero")
        #expect(say("It has 42 files and 1,250 lines.") == "It has forty-two files and one thousand two hundred fifty lines.")
        #expect(say("1,000,000 rows") == "one million rows")
        #expect(say("Exactly 12345 bytes") == "Exactly twelve thousand three hundred forty-five bytes")
    }

    @Test func listsOfSmallNumbersStayApart() {
        #expect(say("1,2,3") == "one,two,three")
    }

    @Test func twoNumbersJoinedByADashAreARange() {
        #expect(say("pages 10-20") == "pages ten to twenty")
        #expect(say("in 2020–2024") == "in twenty twenty to twenty twenty-four")
        #expect(say("2020–2024") == "two thousand twenty to two thousand twenty-four")
        #expect(say("10-20%") == "ten to twenty percent")
        #expect(say("$10-$20") == "ten dollars to twenty dollars")
        #expect(say("1.5-2.5") == "one point five to two point five")
        // A minus that starts the first number still makes it negative.
        #expect(say("-5-10") == "minus five to ten")
        // A dash after a word is a hyphen, as in a name.
        #expect(say("COVID-19") == "COVID-nineteen")
    }

    @Test func threeOrMoreNumbersJoinedByDashesAreReadGroupByGroup() {
        #expect(say("Call 555-123-4567.") == "Call five five five, one two three, four five six seven.")
        #expect(say("on 2026-11-13") == "on two zero two six, one one, one three")
        #expect(say("1-800-555-0199") == "one, eight zero zero, five five five, zero one nine nine")
    }

    @Test func decimalsAndVersionsAreReadDigitByDigitAfterThePoint() {
        #expect(say("It took 3.5 seconds.") == "It took three point five seconds.")
        #expect(say("0.25") == "zero point two five")
        #expect(say("Swift 6.2.1 is out.") == "Swift six point two point one is out.")
        // A full stop after a number ends the sentence.
        #expect(say("The answer is 7.") == "The answer is seven.")
    }

    @Test func decimalsWithoutTheirLeadingZero() {
        #expect(say(".25 seconds") == "point two five seconds")
        #expect(say("up .5%") == "up point five percent")
        #expect(say("-.5") == "minus point five")
        #expect(say("(.75)") == "(point seven five)")
        // A dot after a word or a number isn't a decimal point.
        #expect(say("file.25") == "file.twenty-five")
    }

    @Test func numbersWithALeadingZeroAreReadDigitByDigit() {
        #expect(say("Call 02079460958") == "Call zero two zero seven nine four six zero nine five eight")
        #expect(say("code 0042") == "code zero zero four two")
        #expect(say("00") == "zero zero")
        // Not a decimal below one, nor a time.
        #expect(say("0.5") == "zero point five")
        #expect(say("at 09:30") == "at nine thirty")
        #expect(say("at 09:05") == "at nine oh five")
    }

    @Test func negatives() {
        #expect(say("It is -5 outside.") == "It is minus five outside.")
        #expect(say("-3.5") == "minus three point five")
        #expect(say("(−2)") == "(minus two)")
    }

    @Test func percentages() {
        #expect(say("50% done") == "fifty percent done")
        #expect(say("up 2.5% today") == "up two point five percent today")
        #expect(say("-10%") == "minus ten percent")
    }

    @Test func money() {
        #expect(say("It costs $20.") == "It costs twenty dollars.")
        #expect(say("$1") == "one dollar")
        #expect(say("$3.50") == "three dollars and fifty cents")
        #expect(say("$1.01") == "one dollar and one cent")
        #expect(say("$0.99") == "ninety-nine cents")
        #expect(say("$4.5") == "four dollars and fifty cents")
        #expect(say("$5.00") == "five dollars")
        #expect(say("$1,200") == "one thousand two hundred dollars")
        #expect(say("$2.5 million") == "two point five million dollars")
        #expect(say("$20 thousand") == "twenty thousand dollars")
        #expect(say("$3 billion") == "three billion dollars")
        // Scales written short, before any reading as dollars and cents.
        #expect(say("$2.5M") == "two point five million dollars")
        #expect(say("$5m") == "five million dollars")
        #expect(say("$20k") == "twenty thousand dollars")
        #expect(say("raised $1.2K.") == "raised one point two thousand dollars.")
        #expect(say("$3B") == "three billion dollars")
        #expect(say("$4.5bn") == "four point five billion dollars")
        #expect(say("€2bn") == "two billion euros")
        #expect(say("€15") == "fifteen euros")
        #expect(say("£2.20") == "two pounds and twenty pence")
    }

    @Test func ordinals() {
        #expect(say("1st") == "first")
        #expect(say("2nd") == "second")
        #expect(say("3rd") == "third")
        #expect(say("4th") == "fourth")
        #expect(say("the 11th, 12th and 13th") == "the eleventh, twelfth and thirteenth")
        #expect(say("21st") == "twenty-first")
        #expect(say("42nd") == "forty-second")
        #expect(say("the 20th time") == "the twentieth time")
        #expect(say("100th") == "one hundredth")
        #expect(say("3RD") == "third")
    }

    @Test func times() {
        #expect(say("Meet at 10:30.") == "Meet at ten thirty.")
        #expect(say("9:05") == "nine oh five")
        #expect(say("at 10:00") == "at ten o'clock")
        #expect(say("at 7:00 PM") == "at seven PM")
        #expect(say("23:59") == "twenty-three fifty-nine")
    }

    @Test func yearsAfterAWordThatIntroducesOne() {
        #expect(say("in 2026") == "in twenty twenty-six")
        #expect(say("since 1999") == "since nineteen ninety-nine")
        #expect(say("November 13, 2026") == "November thirteen, twenty twenty-six")
        #expect(say("from 2020 to 2026") == "from twenty twenty to twenty twenty-six")
        #expect(say("in 1905") == "in nineteen oh five")
        #expect(say("in 1900") == "in nineteen hundred")
        #expect(say("in 2005") == "in two thousand five")
        #expect(say("in 2000") == "in two thousand")
        // Not after such a word, a four-digit number is a number.
        #expect(say("2048 bytes") == "two thousand forty-eight bytes")
    }

    @Test func numberedLists() {
        #expect(say("1. Build\n2. Test") == "one. Build\ntwo. Test")
    }

    @Test func digitsJoinedToLettersAreSpelledApart() {
        #expect(say("an mp3 file") == "an mp three file")
        #expect(say("a 4K screen") == "a four K screen")
    }

    @Test func textWithoutNumbersIsUnchanged() {
        #expect(say("Hello there. How are you?") == "Hello there. How are you?")
        #expect(say("") == "")
    }

    @Test func digitsTooManyForANumberAreReadOneByOne() {
        #expect(say("12345678901234567890123") == "one two three four five six seven eight nine zero one two three four five six seven eight nine zero one two three")
    }
}
