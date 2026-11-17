import Testing
@testable import VoiceLoop

/// Telling a reply's own words, heard back through the microphone, from Adam's.
@Suite struct ReplyEchoTests {
    private let reply = ReplyEcho(reply: "Hi Adam, I can hear you loud and clear. What would you like to do?")

    @Test func theReplyHeardBackIsEchoEvenWithAWordMisheard() {
        #expect(reply.isEcho("Hi Adam, I can hear you loud and clear."))
        #expect(reply.isEcho("Hi Adam"))
        #expect(reply.isEcho("what would you like"))
        // From a real session: 8 of its 9 words line up with the reply.
        #expect(reply.isEcho("Hey Adam, I can hear you loud and clear."))
        // Two thirds of three words, rounded up, is two.
        #expect(reply.isEcho("Hey Adam I"))
    }

    @Test func wordsThatAreNotInTheReplyAreNotEcho() {
        #expect(!reply.isEcho("Wait, stop."))
        #expect(!reply.isEcho("Hold on a second"))
    }

    @Test func oneWordIsEchoOnlyIfTheReplySaysIt() {
        #expect(reply.isEcho("Hi"))
        #expect(reply.isEcho("clear"))
        #expect(!reply.isEcho("Hey"))
        #expect(!reply.isEcho("Stop."))
    }

    @Test func twoWordsAreEchoOnlyIfTheReplySaysBoth() {
        #expect(reply.isEcho("loud and"))
        #expect(!reply.isEcho("Hey Adam"))
        #expect(!reply.isEcho("Hi, Adams."))
        // Two of four line up: not two thirds.
        #expect(!reply.isEcho("Hey Adams, I can"))
    }

    @Test func wordsTheReplyHasFarApartAreNotEcho() {
        // "on" is in the reply, but "hold" isn't.
        let goesOn = ReplyEcho(reply: "This reply goes on and on, with enough words to still be playing.")
        #expect(!goesOn.isEcho("hold on"))
        #expect(!goesOn.isEcho("wait what"))
        // Both are in the reply, but not near each other.
        #expect(!reply.isEcho("hi clear"))
        // "can", "you" and "that" are in the reply in that order, but far apart.
        let weather = ReplyEcho(
            reply: "I can look up the weather for the week ahead, and when the forecast is ready "
                + "I will send it to you, along with a note about that storm on Friday."
        )
        #expect(!weather.isEcho("Wait, can you say that again?"))
        // A stretch of it still is echo.
        #expect(weather.isEcho("I will send it to you"))
    }

    @Test func caseAndPunctuationDoNotMatterAndEmptyTextIsNotEcho() {
        #expect(reply.isEcho("HI, ADAM!"))
        #expect(reply.isEcho("loud... and, clear?"))
        // Apostrophes are dropped on both sides.
        #expect(ReplyEcho(reply: "I'm here.").isEcho("Im here"))
        #expect(ReplyEcho(reply: "I’m here.").isEcho("I'm here"))
        #expect(!reply.isEcho(""))
        #expect(!reply.isEcho(" ... "))
        // Filler words aren't words.
        #expect(!reply.isEcho("uh"))
        #expect(!ReplyEcho(reply: "").isEcho("Hi"))
    }

    @Test func wordsOutOfTheReplysOrderLineUpLess() {
        let counting = ReplyEcho(reply: "one two three four")
        #expect(counting.isEcho("one two three four"))
        #expect(counting.isEcho("one two"))
        #expect(!counting.isEcho("two one"))
        // Only one of them lines up, whichever it is.
        #expect(!counting.isEcho("four three two one"))
        #expect(!counting.isEcho("four three two"))
        // Two of the three line up ("two four" or "one four"), whatever the third does.
        #expect(counting.isEcho("two one four"))
    }

    @Test func aStretchCanHaveTwoWordsTheRecognizerMissedButNotThree() {
        // Two heard words are matched against four of the reply's, so both line up across two
        // that weren't heard.
        #expect(ReplyEcho(reply: "one two three four").isEcho("one four"))
        // Across three, no four of the reply's words hold both.
        #expect(!ReplyEcho(reply: "one two three five four").isEcho("one four"))
    }

    @Test func anAlternativeReadingThatIsEchoMakesTheResultEcho() {
        #expect(reply.isEcho(anyOf: ["Hey", "Hi"]))
        #expect(reply.isEcho(anyOf: ["Hey Adam", "Hi Adam"]))
        #expect(!reply.isEcho(anyOf: ["Hey, Adams.", "Hi, Adams."]))
        #expect(!reply.isEcho(anyOf: ["Wait", "Weight"]))
        #expect(!reply.isEcho(anyOf: []))
    }
}
