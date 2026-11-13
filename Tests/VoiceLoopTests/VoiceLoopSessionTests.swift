import Foundation
import Testing
import VoiceLoop
import VoiceLoopTestSupport

// These tests run the real `VoiceLoop` on a `VoiceTestBed`: the audio engine renders offline,
// the recognizer reports what the test scripts, and replies are spoken by the real
// `AVSpeechSynthesizer` into the engine.

/// The next utterance the loop finishes. Waits for it.
@MainActor
func nextUtterance(of loop: VoiceLoop) async -> Utterance? {
    for await utterance in loop.utterances {
        return utterance
    }
    return nil
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ListeningTests {
    @Test func whatIsHeardShowsAsTheLiveTranscriptAndIsSentAfterAPause() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        loop.pauseThreshold = .milliseconds(50)

        try await loop.start()
        #expect(loop.state == .listening(partial: ""))

        bed.recognizer.hear("Mark that", over: 0...0.5)
        #expect(await eventually { loop.state == .listening(partial: "Mark that") })
        bed.recognizer.hear("Mark that read.", over: 0...1, isFinal: true, alternatives: ["Mark that red."])

        let utterance = await nextUtterance(of: loop)
        #expect(utterance?.text == "Mark that read.")
        #expect(utterance?.alternatives == ["Mark that red."])
        #expect(await eventually { loop.state == .listening(partial: "") })

        loop.stop()
        #expect(loop.state == .off)
    }

    @Test func theMicrophoneReachesTheRecognizerInItsOwnFormat() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()

        try await loop.start()

        // 16 kHz audio for the recognizer, converted from the microphone's format.
        #expect(await eventually { bed.recognizer.heardFrames > 16_000 })
        loop.stop()
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SpeakingTests {
    @Test func aReplyIsSpokenThenTheLoopListensAgain() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        try await loop.start()

        loop.speak("Hi.")

        #expect(loop.state == .speaking)
        #expect(await eventually { loop.state == .listening(partial: "") })
        loop.stop()
    }
}
