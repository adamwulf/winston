import Testing
@testable import VoiceLoop

/// Telling a reply's own words, heard back through the microphone, from Adam's.
@Suite struct ReplyEchoTests {
    private let reply = ReplyEcho(reply: "Hi Adam, I can hear you loud and clear. What would you like to do?")

    @Test func theReplyHeardBackIsEchoEvenWithAWordMisheard() {
        #expect(reply.isEcho("Hi Adam, I can hear you loud and clear."))
        // From a real session: 8 of its 9 words line up with the reply.
        #expect(reply.isEcho("Hey Adam, I can hear you loud and clear."))
        #expect(reply.isEcho("what would you like"))
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
        // Only one of them lines up, whichever it is.
        #expect(!counting.isEcho("four three two one"))
        #expect(!counting.isEcho("four three two"))
        // Two of the three line up ("two four" or "one four"), whatever the third does.
        #expect(counting.isEcho("two one four"))
    }

    @Test func anAlternativeReadingThatIsEchoMakesTheResultEcho() {
        #expect(reply.isEcho(anyOf: ["Hey", "Hi"]))
        #expect(reply.isEcho(anyOf: ["Hey, Adams.", "Hi, Adams."]))
        #expect(!reply.isEcho(anyOf: ["Wait", "Weight"]))
        #expect(!reply.isEcho(anyOf: []))
    }
}
