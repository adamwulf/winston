import CoreMedia
import Foundation
import Speech
import Testing
@testable import VoiceLoop

@Suite struct UtteranceMessageTextTests {
    @Test func plainTextGetsVoicePrefix() {
        #expect(Utterance(text: "hello").messageText == "🎙️ hello")
    }

    @Test func oneDifferingAlternate() {
        let utterance = Utterance(text: "mark that red", alternatives: ["mark that read"])
        #expect(utterance.messageText == "🎙️ mark that red (alt: mark that read)")
    }

    @Test func twoDifferingAlternates() {
        let utterance = Utterance(text: "mark that red", alternatives: ["mark that read", "mark the red"])
        #expect(utterance.messageText == "🎙️ mark that red (alt: mark that read; mark the red)")
    }

    @Test func atMostTwoAlternates() {
        let utterance = Utterance(text: "a", alternatives: ["b", "c", "d"])
        #expect(utterance.messageText == "🎙️ a (alt: b; c)")
    }

    @Test func alternatesMatchingTextAreDropped() {
        let utterance = Utterance(text: "Mark that red", alternatives: ["  mark THAT red ", "Mark that red"])
        #expect(utterance.messageText == "🎙️ Mark that red")
    }

    @Test func matchingAlternatesDontUseUpTheTwoSlots() {
        let utterance = Utterance(text: "red", alternatives: ["Red", "read", "", "READ", "rad", "rid"])
        #expect(utterance.messageText == "🎙️ red (alt: read; rad)")
    }

    @Test func alwaysOneLine() {
        let utterance = Utterance(text: "first line\nsecond  line\n", alternatives: ["other\nreading"])
        #expect(utterance.messageText == "🎙️ first line second line (alt: other reading)")
        let hasNewline = utterance.messageText.contains { $0.isNewline }
        #expect(!hasNewline)
    }
}

@Suite struct SpokenTextTests {
    @Test func dropsFencedCodeBlocks() {
        let text = "Here is the fix:\n```swift\nlet x = 1\nprint(x)\n```\nThat's it."
        #expect(SpokenText.speakable(text) == "Here is the fix:\nThat's it.")
    }

    @Test func dropsTildeFencesAndUnclosedFences() {
        #expect(SpokenText.speakable("Before\n~~~\ncode\n~~~\nAfter") == "Before\nAfter")
        #expect(SpokenText.speakable("Before\n```\ncode that never ends") == "Before")
    }

    @Test func dropsOneLineFence() {
        #expect(SpokenText.speakable("Run\n```ls -la```\nthen continue") == "Run\nthen continue")
    }

    @Test func stripsEmphasisKeepingWords() {
        let text = "**bold** and *italic* and __strong__ and _em_ and ~~gone~~"
        #expect(SpokenText.speakable(text) == "bold and italic and strong and em and gone")
    }

    @Test func leavesLoneAsterisksAndSnakeCaseAlone() {
        #expect(SpokenText.speakable("2 * 3 * 4 is 24") == "2 * 3 * 4 is 24")
        #expect(SpokenText.speakable("set my_var_name to 3") == "set my_var_name to 3")
    }

    @Test func stripsHeadingsAndBullets() {
        let text = "## Summary\n- first item\n* second item\n+ third item\n  - nested item"
        #expect(SpokenText.speakable(text) == "Summary\nfirst item\nsecond item\nthird item\nnested item")
    }

    @Test func keepsInlineCodeContents() {
        #expect(SpokenText.speakable("Run `swift test` now") == "Run swift test now")
    }

    @Test func linksBecomeTheirText() {
        #expect(SpokenText.speakable("See [the docs](https://example.com/a/b).") == "See the docs.")
    }

    @Test func bareURLsBecomeALink() {
        #expect(SpokenText.speakable("Open https://example.com/a?b=c.") == "Open a link.")
        #expect(SpokenText.speakable("(see http://x.org/y)") == "(see a link)")
    }

    @Test func absolutePathsBecomeLastComponent() {
        let text = "Edited /Users/adam/Developer/winston/Sources/VoiceLoop/VoiceLoop.swift today."
        #expect(SpokenText.speakable(text) == "Edited VoiceLoop.swift today.")
        #expect(SpokenText.speakable("Saved to ~/notes/todo.md") == "Saved to todo.md")
        #expect(SpokenText.speakable("Look in /tmp/build/") == "Look in build")
        #expect(SpokenText.speakable("Wrote `/tmp/out/report.txt`") == "Wrote report.txt")
    }

    @Test func leavesSlashCommandsAndRelativePathsAlone() {
        #expect(SpokenText.speakable("/compact") == "/compact")
        #expect(SpokenText.speakable("and/or") == "and/or")
        #expect(SpokenText.speakable("in Sources/VoiceLoop") == "in Sources/VoiceLoop")
    }

    @Test func collapsesWhitespace() {
        #expect(SpokenText.speakable("  a   b\t c\n\n\n d  \n") == "a b c\nd")
    }

    @Test func leavesEmojiPrefixAlone() {
        #expect(SpokenText.speakable("✅ **Done**: shipped") == "✅ Done: shipped")
        #expect(SpokenText.speakable("👀 looking") == "👀 looking")
    }

    @Test func plainTextIsUnchanged() {
        #expect(SpokenText.speakable("The build passed. Want me to merge it?") == "The build passed. Want me to merge it?")
    }
}

@Suite struct VoiceActivityDetectorTests {
    @Test func firstBufferOnlySetsTheNoiseFloor() {
        var detector = VoiceActivityDetector()
        let isVoice = detector.process(rms: 0.5)
        #expect(!isVoice)
        #expect(detector.noiseFloor == 0.5)
    }

    @Test func speechWellAboveTheNoiseFloorIsVoice() {
        var detector = VoiceActivityDetector()
        for _ in 0..<20 { _ = detector.process(rms: 0.004) }
        let speechStart = detector.process(rms: 0.05)
        let speech = detector.process(rms: 0.05)
        let roomNoise = detector.process(rms: 0.005)
        #expect(!speechStart)
        #expect(speech)
        #expect(!roomNoise)
    }

    @Test func aSingleLoudBufferLikeAKeyClickIsNotVoice() {
        var detector = VoiceActivityDetector()
        for _ in 0..<20 { _ = detector.process(rms: 0.004) }
        let click = detector.process(rms: 0.08)
        let after = detector.process(rms: 0.004)
        #expect(!click)
        #expect(!after)
    }

    @Test func nearSilenceIsNeverVoice() {
        var detector = VoiceActivityDetector()
        _ = detector.process(rms: 0.0001)
        let isVoice = detector.process(rms: 0.002)
        #expect(!isVoice)
    }

    @Test func aLouderRoomIsLearned() {
        var detector = VoiceActivityDetector()
        _ = detector.process(rms: 0.004)
        // A steady fan or TV at 0.02: voice at first, then the floor catches up.
        var stillVoice = true
        for _ in 0..<400 { stillVoice = detector.process(rms: 0.02) }
        #expect(!stillVoice)
    }

    @Test func peakLevelIsTheLoudestBufferSinceLastTaken() {
        let activity = VoiceActivity()
        let quiet = [Float](repeating: 0.01, count: 256)
        let loud = [Float](repeating: -0.1, count: 256)
        quiet.withUnsafeBufferPointer { activity.process($0.baseAddress!, count: $0.count) }
        loud.withUnsafeBufferPointer { activity.process($0.baseAddress!, count: $0.count) }
        quiet.withUnsafeBufferPointer { activity.process($0.baseAddress!, count: $0.count) }
        #expect(activity.takePeakDecibels() == -20)
        // Taking it starts over; nothing heard since reads as silence.
        #expect(activity.takePeakDecibels() == -120)
    }
}

@Suite struct PauseDetectorTests {
    let start = ContinuousClock.Instant.now

    func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        start.advanced(by: .milliseconds(milliseconds))
    }

    @Test func emptyTextNeverCompletes() {
        var detector = PauseDetector(pauseThreshold: .milliseconds(1200))
        #expect(!detector.isComplete(at: at(10_000)))
        detector.update(text: "   ", at: at(0))
        #expect(!detector.isComplete(at: at(10_000)))
    }

    @Test func completesOnceTextIsUnchangedForThreshold() {
        var detector = PauseDetector(pauseThreshold: .milliseconds(1200))
        detector.update(text: "hello.", at: at(0))
        #expect(!detector.isComplete(at: at(1199)))
        #expect(detector.isComplete(at: at(1200)))
    }

    @Test func unfinishedSentenceWaitsTwiceAsLong() {
        var detector = PauseDetector(pauseThreshold: .milliseconds(1200))
        detector.update(text: "It does seem I'm able to talk, but it's uh", at: at(0))
        #expect(!detector.isComplete(at: at(2399)))
        #expect(detector.isComplete(at: at(2400)))
    }

    @Test func closingPunctuationRestartsTheShorterPause() {
        var detector = PauseDetector(pauseThreshold: .milliseconds(1200))
        detector.update(text: "if I can talk over you", at: at(0))
        detector.update(text: "if I can talk over you?", at: at(500))
        #expect(!detector.isComplete(at: at(1699)))
        #expect(detector.isComplete(at: at(1700)))
    }

    @Test func voiceKeepsTheUtteranceOpenWhileTheTranscriptLags() {
        // The paragraph case: the transcript stalls after a sentence while the speaker keeps talking.
        var detector = PauseDetector(pauseThreshold: .milliseconds(1200))
        detector.update(text: "Yeah, let me see if it'll understand this.", at: at(0))
        detector.heardVoice(at: at(1000))
        detector.heardVoice(at: at(2000))
        #expect(!detector.isComplete(at: at(3000)))
        #expect(detector.isComplete(at: at(3200)))
    }

    @Test func endlessVoiceStillCompletesAfterFourPauses() {
        var detector = PauseDetector(pauseThreshold: .milliseconds(1200))
        detector.update(text: "turn it down.", at: at(0))
        for time in stride(from: 100, through: 6000, by: 100) {
            detector.heardVoice(at: at(time))
        }
        #expect(!detector.isComplete(at: at(4799)))
        #expect(detector.isComplete(at: at(4800)))
    }

    @Test func resetForgetsVoice() {
        var detector = PauseDetector(pauseThreshold: .milliseconds(1200))
        detector.heardVoice(at: at(1000))
        detector.reset()
        detector.update(text: "next.", at: at(0))
        #expect(detector.isComplete(at: at(1200)))
    }

    @Test func sentenceEndingsIgnoreClosingQuotesAndBrackets() {
        #expect(PauseDetector.endsSentence("He said \"done.\""))
        #expect(PauseDetector.endsSentence("(really!) "))
        #expect(PauseDetector.endsSentence("wait…"))
        #expect(!PauseDetector.endsSentence("Great. I want"))
        #expect(!PauseDetector.endsSentence("one, two,"))
    }

    @Test func sameTextDoesNotRestartThePause() {
        var detector = PauseDetector(pauseThreshold: .milliseconds(1200))
        detector.update(text: "hello.", at: at(0))
        detector.update(text: "hello.", at: at(1000))
        #expect(detector.isComplete(at: at(1200)))
    }

    @Test func changedTextRestartsThePause() {
        var detector = PauseDetector(pauseThreshold: .milliseconds(1200))
        detector.update(text: "hello.", at: at(0))
        detector.update(text: "hello there.", at: at(1000))
        #expect(!detector.isComplete(at: at(2199)))
        #expect(detector.isComplete(at: at(2200)))
    }

    @Test func resetForgetsText() {
        var detector = PauseDetector(pauseThreshold: .milliseconds(1200))
        detector.update(text: "hello", at: at(0))
        detector.reset()
        #expect(detector.text.isEmpty)
        #expect(!detector.isComplete(at: at(5000)))
    }

    @Test func thresholdChangesApply() {
        var detector = PauseDetector(pauseThreshold: .milliseconds(1200))
        detector.update(text: "hello.", at: at(0))
        detector.pauseThreshold = .milliseconds(500)
        #expect(detector.isComplete(at: at(500)))
    }
}

@Suite struct TranscriptTests {
    /// A result whose runs carry word timings in seconds.
    func piece(_ words: [(String, Double)], end: Double, final: Bool = false, alternatives: [[(String, Double)]] = []) -> TranscriptPiece {
        let start = words.first?.1 ?? end
        return TranscriptPiece(
            text: timed(words, end: end),
            alternatives: alternatives.map { timed($0, end: end) },
            range: CMTimeRange(start: time(start), end: time(end)),
            isFinal: final
        )
    }

    func timed(_ words: [(String, Double)], end: Double) -> AttributedString {
        var result = AttributedString()
        for (index, (word, start)) in words.enumerated() {
            let wordEnd = index + 1 < words.count ? words[index + 1].1 : end
            var run = AttributedString(index == 0 ? word : " " + word)
            run.audioTimeRange = CMTimeRange(start: time(start), end: time(wordEnd))
            result += run
        }
        return result
    }

    func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1000)
    }

    @Test func volatileResultsReplaceEachOtherAndFinalsAccumulate() {
        var transcript = Transcript()
        var applied = transcript.apply(piece([("mark", 0)], end: 0.4))
        #expect(applied)
        #expect(transcript.text == "mark")
        applied = transcript.apply(piece([("mark", 0), ("that", 0.4)], end: 0.8))
        #expect(applied)
        #expect(transcript.text == "mark that")
        applied = transcript.apply(piece([("Mark", 0), ("that", 0.4), ("red.", 0.8)], end: 1.2, final: true))
        #expect(applied)
        #expect(transcript.text == "Mark that red.")
        applied = transcript.apply(piece([("then", 2)], end: 2.3))
        #expect(applied)
        #expect(transcript.text == "Mark that red. then")
        #expect(transcript.wordCount == 4)
    }

    @Test func takeReturnsTextWithDifferingAlternatesAndClears() {
        var transcript = Transcript()
        _ = transcript.apply(piece(
            [("mark", 0), ("that", 0.4), ("red", 0.8)], end: 1.2, final: true,
            alternatives: [[("mark", 0), ("that", 0.4), ("red", 0.8)], [("mark", 0), ("that", 0.4), ("read", 0.8)]]
        ))
        let utterance = transcript.take()
        #expect(utterance == Utterance(text: "mark that red", alternatives: ["mark that read"]))
        #expect(utterance.messageText == "🎙️ mark that red (alt: mark that read)")
        #expect(transcript.isEmpty)
    }

    @Test func alternatesTakeEachPhrasesNextBestReadingFirst() {
        var transcript = Transcript()
        _ = transcript.apply(piece([("one", 0)], end: 1, final: true,
                                   alternatives: [[("one", 0)], [("won", 0)], [("wan", 0)]]))
        _ = transcript.apply(piece([("two", 1)], end: 2, final: true,
                                   alternatives: [[("two", 1)], [("too", 1)]]))
        #expect(transcript.take().alternatives == ["won", "too", "wan"])
    }

    @Test func alternatesThatOnlyChangePunctuationFillersOrLengthAreDropped() {
        var transcript = Transcript()
        // From a real session: none of these is another reading of the same words.
        _ = transcript.apply(piece([("Uh,", 0), ("still", 0.2), ("just", 0.4)], end: 0.6, final: true,
                                   alternatives: [[("Still,", 0), ("just", 0.4)]]))
        _ = transcript.apply(piece([("Great.", 1)], end: 1.5, final: true,
                                   alternatives: [[("Great,", 1)], [("Great", 1)]]))
        _ = transcript.apply(piece([("checking", 2), ("if", 2.3), ("it", 2.5), ("works.", 2.7)], end: 3, final: true,
                                   alternatives: [[("works?", 2.7)]]))
        let utterance = transcript.take()
        #expect(utterance.alternatives.isEmpty)
        #expect(utterance.messageText == "🎙️ Uh, still just Great. checking if it works.")
    }

    @Test func rereadingsAreRecognizedIgnoringCaseAndPunctuation() {
        #expect(Utterance.isRereading("mark that read.", of: "Mark that red"))
        #expect(!Utterance.isRereading("Mark, that red?", of: "mark that red."))
        // From a real session: spelling variants aren't other readings.
        #expect(!Utterance.isRereading("Im", of: "I'm"))
        #expect(!Utterance.isRereading("OK, great.", of: "Okay, great."))
        #expect(!Utterance.isRereading("uh mark that red", of: "mark that red"))
        #expect(!Utterance.isRereading("works?", of: "checking if it works."))
        #expect(!Utterance.isRereading("", of: "red"))
    }

    @Test func messageTextDropsAlternatesThatOnlyChangePunctuation() {
        let utterance = Utterance(text: "hopefully.", alternatives: ["hopefully..", "Hopefully!"])
        #expect(utterance.messageText == "🎙️ hopefully.")
    }

    @Test func lateResultsForTakenAudioAreIgnored() {
        var transcript = Transcript()
        _ = transcript.apply(piece([("mark", 0), ("that", 0.4), ("red", 0.8)], end: 1.2))
        _ = transcript.take()
        // The final for the same audio arrives after the utterance was sent.
        var applied = transcript.apply(piece([("Mark", 0), ("that", 0.4), ("red.", 0.8)], end: 1.5, final: true))
        #expect(!applied)
        #expect(transcript.isEmpty)
        // A refined volatile result for the old audio is ignored too.
        applied = transcript.apply(piece([("mark", 0), ("that", 0.4), ("read", 0.8)], end: 1.1))
        #expect(!applied)
        #expect(transcript.isEmpty)
    }

    @Test func straddlingResultKeepsOnlyNewWords() {
        var transcript = Transcript()
        _ = transcript.apply(piece([("mark", 0), ("that", 0.4), ("red", 0.8)], end: 1.2))
        _ = transcript.take()
        // The next result still covers the old phrase plus new speech.
        let applied = transcript.apply(piece(
            [("mark", 0), ("that", 0.4), ("red", 0.8), ("and", 3), ("archive", 3.3)], end: 3.8,
            alternatives: [[("mark", 0), ("that", 0.4), ("read", 0.8), ("and", 3), ("archive", 3.3)],
                           [("mark", 0), ("that", 0.4), ("red", 0.8), ("and", 3), ("achieve", 3.3)]]
        ))
        #expect(applied)
        #expect(transcript.text == "and archive")
        // The alternate that only differed in already-sent words now matches and is dropped.
        #expect(transcript.take() == Utterance(text: "and archive", alternatives: ["and achieve"]))
    }

    @Test func newResultsAfterTakeAreKept() {
        var transcript = Transcript()
        _ = transcript.apply(piece([("hello", 0)], end: 1, final: true))
        _ = transcript.take()
        let applied = transcript.apply(piece([("again", 2)], end: 2.5))
        #expect(applied)
        #expect(transcript.text == "again")
    }

    @Test func discardConsumesAudioLikeTake() {
        var transcript = Transcript()
        _ = transcript.apply(piece([("not", 0), ("this", 0.3)], end: 0.8))
        transcript.discard()
        #expect(transcript.isEmpty)
        var applied = transcript.apply(piece([("Not", 0), ("this.", 0.3)], end: 1.0, final: true))
        #expect(!applied)
        applied = transcript.apply(piece([("but", 0.3), ("this", 2)], end: 2.4))
        #expect(applied)
        #expect(transcript.text == "this")
    }

    @Test func volatileFinalizedWithoutResendIsKept() {
        var transcript = Transcript()
        _ = transcript.apply(piece([("hello", 0)], end: 1))
        // The next phrase starts after the first ends, so the first was finalized as-is.
        _ = transcript.apply(piece([("world", 1.5)], end: 2))
        #expect(transcript.text == "hello world")
        // A refinement of the second phrase still replaces only that phrase.
        _ = transcript.apply(piece([("world", 1.5), ("again", 1.9)], end: 2.4))
        #expect(transcript.text == "hello world again")
        #expect(transcript.take().text == "hello world again")
    }

    @Test func volatileFinalizedWithoutResendIsKeptBeforeALaterFinal() {
        var transcript = Transcript()
        _ = transcript.apply(piece([("hello", 0)], end: 1))
        _ = transcript.apply(piece([("there.", 1.2)], end: 1.8, final: true))
        #expect(transcript.text == "hello there.")
    }

    @Test func emptyVolatileResultEmptiesTheTranscript() {
        var transcript = Transcript()
        _ = transcript.apply(piece([("uh", 0)], end: 0.5))
        #expect(!transcript.isEmpty)
        // The transcriber revokes its guess for the same audio.
        let applied = transcript.apply(TranscriptPiece(
            text: AttributedString(),
            alternatives: [],
            range: CMTimeRange(start: time(0), end: time(0.8)),
            isFinal: false
        ))
        #expect(applied)
        #expect(transcript.isEmpty)
    }

    @Test func consumeIgnoresLaterResultsForThatAudio() {
        var transcript = Transcript()
        // Echo heard while speaking was ignored; its audio is consumed when speech ends.
        transcript.consume(through: time(5.4))
        var applied = transcript.apply(piece([("the", 5)], end: 5.8, final: true))
        #expect(!applied)
        #expect(transcript.isEmpty)
        applied = transcript.apply(piece([("the", 5), ("real", 7)], end: 7.5))
        #expect(applied)
        #expect(transcript.text == "real")
        // Consuming never moves backwards.
        transcript.consume(through: time(1))
        #expect(transcript.consumedThrough == time(5.4))
    }

    @Test func fedAudioClockTracksTheAnalyzerTimeline() {
        let clock = FedAudioClock(sampleRate: 16_000)
        #expect(clock.time == .zero)
        clock.add(frames: 8_000)
        clock.add(frames: 8_000)
        #expect(clock.time == time(1))
        // Consuming through the fed time drops the echo tail whose result arrives late.
        var transcript = Transcript()
        transcript.consume(through: clock.time)
        let applied = transcript.apply(piece([("done", 0.7)], end: 1.0, final: true))
        #expect(!applied)
    }

    @Test func wordsWithoutTimingAreDroppedWhenTrimming() {
        #expect(Transcript.words(of: AttributedString("untimed words"), startingAt: time(1)) == "")
    }
}
