import AVFoundation
import Foundation
import Testing
import VoiceLoop
import VoiceLoopTestSupport

// These tests run the real `VoiceLoop` on a `VoiceTestBed`: the audio engine renders offline,
// the recognizer reports what the test scripts, and replies are spoken by the real
// `AVSpeechSynthesizer` into the engine. `bed.audio.playedFrames` is how much sound came out
// of the speaker.
//
// Audio times: the offline engine runs far faster than real time, so a result "over 0...1" is
// old audio by the time anything has been spoken, and `later` is audio that is always new.

/// A reply long enough to still be playing when a test interrupts it.
private let longReply = "This is a long reply, with enough words to still be playing when the test interrupts it."

/// Audio far enough along the timeline to be new, whatever has been consumed.
private let later: ClosedRange<Double> = 1_000_000...1_000_001

private struct TestFailure: Error, Equatable {}

/// The next utterance the loop finishes. Waits for it.
@MainActor
private func nextUtterance(of loop: VoiceLoop) async -> Utterance? {
    for await utterance in loop.utterances {
        return utterance
    }
    return nil
}

/// Every utterance the loop finishes, for tests that check none was sent.
@MainActor
private final class UtteranceLog {
    private(set) var texts: [String] = []

    init(_ loop: VoiceLoop) {
        // The stream, not the loop, so the log doesn't keep the loop alive.
        let utterances = loop.utterances
        Task { [weak self] in
            for await utterance in utterances {
                self?.texts.append(utterance.text)
            }
        }
    }
}

/// A started loop with a short pause threshold, so utterances finish quickly.
@MainActor
private func startedLoop(on bed: VoiceTestBed) async throws -> VoiceLoop {
    let loop = bed.makeLoop()
    loop.pauseThreshold = .milliseconds(50)
    try await loop.start()
    return loop
}

/// Lets queued main-actor work and the audio engine run for a moment, before checking that
/// something did NOT happen.
private func settle(_ duration: Duration = .milliseconds(250)) async throws {
    try await Task.sleep(for: duration)
}

/// Tells the loop its engine's hardware configuration changed, as AVAudioEngine does.
@MainActor
private func postConfigurationChange(for engine: AVAudioEngine) {
    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
}

// MARK: - Starting

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct StartingTests {
    @Test func startingTwiceKeepsOneListeningSession() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        try await loop.start()

        #expect(loop.state == .listening(partial: ""))
        #expect(bed.recognizers.count == 1)
        #expect(bed.audio.engines.count == 1)
    }

    @Test func withoutMicrophonePermissionTheStartFailsAndTheLoopStaysOff() async throws {
        let bed = VoiceTestBed()
        bed.permissionError = .microphonePermissionDenied
        let loop = bed.makeLoop()

        await #expect(throws: VoiceLoopError.microphonePermissionDenied) {
            try await loop.start()
        }

        #expect(loop.state == .off)
        #expect(bed.recognizers.isEmpty)
        #expect(bed.audio.engines.isEmpty)
    }

    @Test func withoutASpeechModelTheStartFails() async throws {
        let bed = VoiceTestBed()
        bed.recognizerError = VoiceLoopError.speechModelUnavailable
        let loop = bed.makeLoop()

        await #expect(throws: VoiceLoopError.speechModelUnavailable) {
            try await loop.start()
        }

        #expect(loop.state == .off)
        #expect(bed.audio.engines.isEmpty)
    }

    @Test func aRecognizerThatCannotStartTakesTheEngineDownWithIt() async throws {
        let bed = VoiceTestBed()
        bed.recognizerStartError = TestFailure()
        let loop = bed.makeLoop()

        await #expect(throws: TestFailure.self) {
            try await loop.start()
        }

        #expect(loop.state == .off)
        #expect(bed.recognizer.isCancelled)
        #expect(bed.audio.engines.last?.isRunning == false)

        // The failure was one-off: the next start works.
        try await loop.start()
        #expect(loop.state == .listening(partial: ""))
        loop.stop()
    }

    @Test func whenNoEngineCanBeBuiltTheStartFails() async throws {
        let bed = VoiceTestBed()
        bed.engineError = TestFailure()
        let loop = bed.makeLoop()

        await #expect(throws: TestFailure.self) {
            try await loop.start()
        }

        #expect(loop.state == .off)
        #expect(bed.recognizer.isCancelled)
    }

    @Test func whenVoiceProcessingIsUnavailableTheLoopListensWithoutItAndStopsTrying() async throws {
        let bed = VoiceTestBed()
        bed.hasVoiceProcessing = false
        let loop = bed.makeLoop()

        try await loop.start()
        #expect(loop.state == .listening(partial: ""))
        #expect(bed.voiceProcessingAttempts == 1)
        // The engine that failed with voice processing was replaced.
        #expect(bed.audio.engines.count == 2)
        #expect(bed.audio.engines.last?.isRunning == true)

        loop.stop()
        try await loop.start()
        defer { loop.stop() }

        #expect(loop.state == .listening(partial: ""))
        #expect(bed.voiceProcessingAttempts == 1)
    }

    @Test func anEngineThatWillNotStartWithVoiceProcessingIsReplacedByOneWithout() async throws {
        let bed = VoiceTestBed()
        bed.audio.nextEngineCannotStart = true
        let loop = bed.makeLoop()

        try await loop.start()
        defer { loop.stop() }

        #expect(loop.state == .listening(partial: ""))
        #expect(bed.audio.engines.count == 2)
        #expect(bed.audio.engines.first?.isRunning == false)
        #expect(bed.audio.engines.last?.isRunning == true)
    }

    @Test func stoppingWhileWaitingForPermissionAbandonsTheStart() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        bed.whenRequestingPermissions = { loop.stop() }

        try await loop.start()

        #expect(loop.state == .off)
        #expect(bed.audio.engines.isEmpty)
        #expect(bed.recognizers.allSatisfy { !$0.isStarted })
    }

    @Test func stoppingWhileTheRecognizerStartsAbandonsTheStart() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        bed.whenRecognizerStarts = { loop.stop() }

        try await loop.start()

        #expect(loop.state == .off)
        #expect(bed.recognizer.isCancelled)
        #expect(bed.audio.engines.last?.isRunning == false)
    }

    @Test func aStartThatFailsAfterStopStillReportsItsError() async throws {
        let bed = VoiceTestBed()
        bed.permissionError = .speechPermissionDenied
        let loop = bed.makeLoop()
        bed.whenRequestingPermissions = { loop.stop() }

        await #expect(throws: VoiceLoopError.speechPermissionDenied) {
            try await loop.start()
        }

        #expect(loop.state == .off)
    }

    @Test func aReplyThatArrivesWhileStartingIsSpokenOnceListening() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        bed.whenRequestingPermissions = { loop.speak("Hi.") }

        try await loop.start()
        defer { loop.stop() }

        #expect(loop.state == .speaking)
        #expect(await eventually { loop.state == .listening(partial: "") })
        #expect(bed.audio.playedFrames > 0)
    }

    @Test func aReplyQueuedDuringAnAbandonedStartIsNotSpokenLater() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        bed.whenRequestingPermissions = {
            loop.stop()
            loop.speak("Hi.")
        }
        try await loop.start()
        #expect(loop.state == .off)

        bed.whenRequestingPermissions = {}
        try await loop.start()
        defer { loop.stop() }

        #expect(loop.state == .listening(partial: ""))
        try await settle()
        #expect(loop.state == .listening(partial: ""))
        #expect(bed.audio.playedFrames == 0)
    }

    @Test func anEngineThatStopsWhileTheRecognizerStartsIsRebuilt() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        bed.whenRecognizerStarts = {
            // Only the first session's engine stops under it.
            if bed.recognizers.count == 1 {
                bed.audio.engines.last?.stop()
            }
        }

        try await loop.start()
        defer { loop.stop() }

        #expect(await eventually { bed.recognizers.count == 2 && bed.recognizer.isStarted })
        #expect(loop.state == .listening(partial: ""))
        #expect(bed.audio.engines.last?.isRunning == true)
        #expect(bed.recognizers.first?.isCancelled == true)
    }
}

// MARK: - Listening

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ListeningTests {
    @Test func whatIsHeardShowsAsTheLiveTranscriptAndIsSentAfterAPause() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        #expect(loop.state == .listening(partial: ""))

        bed.recognizer.hear("Mark that", over: 0...0.5)
        #expect(await eventually { loop.state == .listening(partial: "Mark that") })
        bed.recognizer.hear("Mark that read.", over: 0...1, isFinal: true, alternatives: ["Mark that red."])

        let utterance = await nextUtterance(of: loop)
        #expect(utterance?.text == "Mark that read.")
        #expect(utterance?.alternatives == ["Mark that red."])
        #expect(await eventually { loop.state == .listening(partial: "") })
    }

    @Test func theMicrophoneReachesTheRecognizerInItsOwnFormat() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        // 16 kHz audio for the recognizer, converted from the microphone's format.
        #expect(bed.recognizer.audioFormat.sampleRate == 16_000)
        #expect(await eventually { bed.recognizer.heardFrames > 16_000 })
    }

    @Test func stopTurnsTheLoopOffAndReleasesTheEngineAndRecognizer() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)

        loop.stop()

        #expect(loop.state == .off)
        #expect(bed.audio.engines.last?.isRunning == false)
        #expect(await eventually { bed.recognizer.isCancelled })
    }

    @Test func discardingDropsTheUtteranceInProgressAndItsLateResults() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        let sent = UtteranceLog(loop)

        bed.recognizer.hear("Never mind", over: 0...1)
        #expect(await eventually { loop.state == .listening(partial: "Never mind") })
        loop.discardCurrentUtterance()
        #expect(loop.state == .listening(partial: ""))

        // The transcriber's final result for the discarded audio arrives afterwards.
        bed.recognizer.hear("Never mind.", over: 0...1, isFinal: true)
        try await settle()
        #expect(loop.state == .listening(partial: ""))
        #expect(sent.texts.isEmpty)

        bed.recognizer.hear("Hello.", over: later, isFinal: true)
        #expect(await eventually { sent.texts == ["Hello."] })
    }

    @Test func discardingWhileOffDoesNothing() {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()

        loop.discardCurrentUtterance()

        #expect(loop.state == .off)
    }

    @Test func aVoiceStillTalkingKeepsTheUtteranceOpen() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        // Long enough to tell "kept open by the voice" from "the pause ran out": without the
        // voice this utterance would be sent after 0.3 s, and with it after 1.2 s at most.
        loop.pauseThreshold = .milliseconds(300)
        try await loop.start()
        defer { loop.stop() }
        let sent = UtteranceLog(loop)

        bed.audio.isVoicePresent = true
        bed.recognizer.hear("Hello there.", over: 0...1)
        try await settle(.milliseconds(700))
        #expect(sent.texts.isEmpty)
        #expect(loop.state == .listening(partial: "Hello there."))

        bed.audio.isVoicePresent = false
        #expect(await eventually { sent.texts == ["Hello there."] })
    }

    @Test func whenTheRecognizerStopsByItselfTheLoopTurnsOff() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)

        bed.recognizer.finish()

        #expect(await eventually { loop.state == .off })
        #expect(bed.audio.engines.last?.isRunning == false)
    }

    @Test func whenTheRecognizerFailsTheLoopTurnsOff() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)

        bed.recognizer.fail(TestFailure())

        #expect(await eventually { loop.state == .off })
        #expect(bed.audio.engines.last?.isRunning == false)
    }

    @Test func resultsAndFailuresFromAStoppedSessionAreIgnored() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        let stopped = bed.recognizer

        // Both reach the loop after it has stopped, before the recognizer is cancelled.
        loop.stop()
        stopped.hear("Too late.", over: 0...1, isFinal: true)
        stopped.fail(TestFailure())
        try await settle()
        #expect(loop.state == .off)

        // A new session is unaffected by the old one.
        try await loop.start()
        defer { loop.stop() }
        try await settle()
        #expect(loop.state == .listening(partial: ""))
        #expect(bed.recognizers.count == 2)
    }

    @Test func aFailureAfterStopLeavesANewSessionRunning() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        let stopped = bed.recognizer

        loop.stop()
        stopped.fail(TestFailure())
        try await loop.start()
        defer { loop.stop() }
        try await settle()

        #expect(loop.state == .listening(partial: ""))
    }
}

// MARK: - Speaking

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SpeakingTests {
    /// Speaks `texts` and waits until the loop has finished them. Returns how much sound
    /// came out of the speaker.
    private func framesPlayed(saying texts: [String], by loop: VoiceLoop, on bed: VoiceTestBed) async -> Int {
        let before = bed.audio.playedFrames
        for text in texts {
            loop.speak(text)
        }
        #expect(loop.state == .speaking)
        #expect(await eventually { loop.state == .listening(partial: "") })
        return bed.audio.playedFrames - before
    }

    @Test func aReplyIsSpokenThenTheLoopListensAgain() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        loop.speak("Hi.")

        #expect(loop.state == .speaking)
        #expect(await eventually { loop.state == .listening(partial: "") })
        #expect(bed.audio.playedFrames > 0)
    }

    @Test func aReplyWhileOffIsNotSpokenLater() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()

        loop.speak("Hi.")
        try await loop.start()
        defer { loop.stop() }
        try await settle()

        #expect(loop.state == .listening(partial: ""))
        #expect(bed.audio.playedFrames == 0)
    }

    @Test func aReplyThatIsOnlyCodeHasNothingToSay() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        loop.speak("```\nlet x = 1\n```")
        try await settle()

        #expect(loop.state == .listening(partial: ""))
        #expect(bed.audio.playedFrames == 0)
    }

    @Test func queuedRepliesAreEachSpokenInFull() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        let first = "One."
        let second = "Two, three, four, five, six."

        let firstAlone = await framesPlayed(saying: [first], by: loop, on: bed)
        let secondAlone = await framesPlayed(saying: [second], by: loop, on: bed)
        let together = await framesPlayed(saying: [first, second], by: loop, on: bed)

        // The speaker meter counts whole render passes of 4096 frames, so allow a few of them.
        #expect(firstAlone > 0)
        #expect(secondAlone > firstAlone)
        #expect(abs(together - (firstAlone + secondAlone)) <= 4 * 4096)
    }

    @Test func aReplyWaitsForTheUtteranceInProgress() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        bed.recognizer.hear("Hold on", over: 0...1)
        #expect(await eventually { loop.state == .listening(partial: "Hold on") })
        loop.speak("Hi.")
        // Not spoken over the user.
        #expect(loop.state == .listening(partial: "Hold on"))
        #expect(bed.audio.playedFrames == 0)

        // Once the utterance is sent, the reply plays.
        #expect(await nextUtterance(of: loop)?.text == "Hold on")
        #expect(await eventually { loop.state == .speaking })
        #expect(await eventually { loop.state == .listening(partial: "") })
        #expect(bed.audio.playedFrames > 0)
    }

    @Test func stopSpeakingCutsTheReplyOffAndDropsTheQueue() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        loop.speak(longReply)
        loop.speak("Two.")
        #expect(await eventually { bed.audio.playedFrames > 0 })
        loop.stopSpeaking()

        #expect(loop.state == .listening(partial: ""))
        // The engine fades a stopped player out over its next render pass or two.
        try await settle(.milliseconds(50))
        let playedWhenStopped = bed.audio.playedFrames
        try await settle()
        #expect(bed.audio.playedFrames == playedWhenStopped)
        #expect(loop.state == .listening(partial: ""))
    }

    @Test func stoppingTheLoopSilencesAReplyBeingSpoken() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)

        loop.speak(longReply)
        #expect(await eventually { bed.audio.playedFrames > 0 })
        loop.stop()

        #expect(loop.state == .off)
        let playedWhenStopped = bed.audio.playedFrames
        try await settle()
        #expect(bed.audio.playedFrames == playedWhenStopped)
    }

    @Test func aVoicePreviewWhileListeningPlaysThroughTheEngine() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        loop.preview("Hello.")

        #expect(loop.state == .speaking)
        #expect(await eventually { loop.state == .listening(partial: "") })
        #expect(bed.audio.playedFrames > 0)
    }

    @Test func aVoicePreviewReplacesTheReplyBeingSpokenAndTheQueue() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        let previewAlone = await framesPlayed(saying: ["Hi."], by: loop, on: bed)

        loop.speak(longReply)
        loop.speak(longReply)
        #expect(await eventually { loop.state == .speaking && bed.audio.playedFrames > previewAlone })
        let playedBeforePreview = bed.audio.playedFrames
        loop.preview("Hi.")

        #expect(loop.state == .speaking)
        #expect(await eventually { loop.state == .listening(partial: "") })
        // Only the preview played after that: neither long reply carried on.
        #expect(abs(bed.audio.playedFrames - playedBeforePreview - previewAlone) <= 4 * 4096)
    }

    @Test func aVoicePreviewWhileOffLeavesTheEngineAlone() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()

        // Nothing to pronounce, so the test run stays silent: this goes to the real speaker.
        loop.preview("")

        #expect(loop.state == .off)
        #expect(bed.audio.engines.isEmpty)

        // Starting stops any preview and listens as usual.
        try await loop.start()
        defer { loop.stop() }
        #expect(loop.state == .listening(partial: ""))
    }

    @Test func anUnknownVoiceFallsBackToAnInstalledOne() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        loop.voiceIdentifier = "com.example.no-such-voice"
        #expect(await framesPlayed(saying: ["Hi."], by: loop, on: bed) > 0)

        loop.voiceIdentifier = try #require(VoiceLoop.availableVoices().last?.id)
        #expect(await framesPlayed(saying: ["Hi."], by: loop, on: bed) > 0)
    }
}

// MARK: - Barge-in and echo

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct BargeInTests {
    @Test func talkingOverAReplyStopsItAndBecomesTheNextUtterance() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        loop.speak(longReply)
        loop.speak("Two.")
        #expect(await eventually { bed.audio.playedFrames > 0 })
        bed.recognizer.hear("Wait.", over: later, isFinal: true)

        #expect(await eventually { loop.state == .listening(partial: "Wait.") })
        let playedWhenInterrupted = bed.audio.playedFrames
        #expect(await nextUtterance(of: loop)?.text == "Wait.")

        // The interrupted reply and the queued one are both gone.
        try await settle()
        #expect(loop.state == .listening(partial: ""))
        #expect(bed.audio.playedFrames == playedWhenInterrupted)
    }

    @Test func soundsShorterThanTheMinimumDoNotInterrupt() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        loop.bargeInMinimumWords = 3

        loop.speak(longReply)
        #expect(await eventually { bed.audio.playedFrames > 0 })
        bed.recognizer.hear("uh", over: later)
        try await settle(.milliseconds(100))
        #expect(loop.state == .speaking)

        bed.recognizer.hear("no stop that", over: later)
        #expect(await eventually { loop.state == .listening(partial: "no stop that") })
    }

    @Test func aSoundIgnoredDuringAReplyIsNotSentAfterwards() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        loop.bargeInMinimumWords = 3
        let sent = UtteranceLog(loop)

        loop.speak("Hi there.")
        bed.recognizer.hear("hi", over: 0...0.2)
        #expect(await eventually { loop.state == .listening(partial: "") })

        // The transcriber finalizes the reply's echo after the reply has ended.
        bed.recognizer.hear("Hi.", over: 0...0.2, isFinal: true)
        try await settle()
        #expect(loop.state == .listening(partial: ""))
        #expect(sent.texts.isEmpty)

        bed.recognizer.hear("Thanks a lot.", over: later, isFinal: true)
        #expect(await eventually { sent.texts == ["Thanks a lot."] })
    }

    @Test func wordsSpokenAsAReplyEndsAreKept() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        loop.speak("Hi.")
        #expect(await eventually { loop.state == .listening(partial: "") })
        // With echo cancellation and nothing ignored, audio from during the reply is the user's.
        bed.recognizer.hear("Thanks.", over: 0...0.5, isFinal: true)

        #expect(await nextUtterance(of: loop)?.text == "Thanks.")
    }

    @Test func withoutEchoCancellationNothingHeardDuringAReplyInterruptsOrIsSent() async throws {
        let bed = VoiceTestBed()
        bed.hasVoiceProcessing = false
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        let sent = UtteranceLog(loop)

        loop.speak("Hi there, friend.")
        #expect(await eventually { bed.audio.playedFrames > 0 })
        // The microphone hears the reply itself.
        bed.recognizer.hear("Hi there", over: 0...0.5)
        try await settle(.milliseconds(100))
        #expect(loop.state == .speaking)
        #expect(await eventually { loop.state == .listening(partial: "") })

        // The echo's final result arrives after the reply has ended.
        bed.recognizer.hear("Hi there, friend.", over: 0...0.5, isFinal: true)
        try await settle()
        #expect(loop.state == .listening(partial: ""))
        #expect(sent.texts.isEmpty)

        bed.recognizer.hear("Hello.", over: later, isFinal: true)
        #expect(await eventually { sent.texts == ["Hello."] })
    }
}

// MARK: - Rebuilding

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RebuildTests {
    @Test func anEngineThatStopsByItselfIsRebuiltAndListeningCarriesOn() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        let first = try #require(bed.audio.engines.last)

        // The audio hardware changed (AirPods connected): the engine stops itself.
        first.stop()
        postConfigurationChange(for: first)

        #expect(await eventually { bed.recognizers.count == 2 && bed.recognizer.isStarted })
        #expect(loop.state == .listening(partial: ""))
        #expect(bed.audio.engines.count == 2)
        #expect(bed.audio.engines.last?.isRunning == true)
        #expect(bed.recognizers.first?.isCancelled == true)

        bed.recognizer.hear("Still here.", over: 0...1, isFinal: true)
        #expect(await nextUtterance(of: loop)?.text == "Still here.")
    }

    @Test func aConfigurationChangeThatLeavesTheEngineRunningChangesNothing() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        let engine = try #require(bed.audio.engines.last)

        postConfigurationChange(for: engine)
        try await settle()

        #expect(bed.recognizers.count == 1)
        #expect(bed.audio.engines.count == 1)
        #expect(loop.state == .listening(partial: ""))
    }

    @Test func aReplyCutOffByARebuildIsSpokenAgain() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        let first = try #require(bed.audio.engines.last)

        loop.speak("Hi there.")
        #expect(await eventually { bed.audio.playedFrames > 0 })
        first.stop()
        postConfigurationChange(for: first)

        // The new engine says it from the start.
        #expect(await eventually { bed.audio.engines.count == 2 && loop.state == .speaking })
        let playedBeforeRebuild = bed.audio.playedFrames
        #expect(await eventually { loop.state == .listening(partial: "") })
        #expect(bed.audio.playedFrames > playedBeforeRebuild)
    }

    @Test func aRebuildThatFailsTurnsTheLoopOff() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        let first = try #require(bed.audio.engines.last)

        bed.permissionError = .microphonePermissionDenied
        first.stop()
        postConfigurationChange(for: first)

        #expect(await eventually { loop.state == .off })
        #expect(bed.audio.engines.count == 1)
    }
}

// MARK: - Voices

@Suite struct VoiceOptionTests {
    @MainActor
    @Test func availableVoicesAreForTheCurrentLanguageBestQualityFirst() throws {
        let voices = VoiceLoop.availableVoices()
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let systemDefault = AVSpeechSynthesisVoice(language: language)?.identifier

        #expect(!voices.isEmpty)
        #expect(Set(voices.map(\.id)).count == voices.count)
        for option in voices {
            let voice = try #require(AVSpeechSynthesisVoice(identifier: option.id))
            #expect(voice.language == language)
            #expect(voice.name == option.name)
            #expect(!voice.voiceTraits.contains(.isNoveltyVoice))
        }
        #expect(voices.map(\.quality) == voices.map(\.quality).sorted(by: >))
        // Within a quality: the system's default voice first, then by name.
        for quality in Set(voices.map(\.quality)) {
            let group = voices.filter { $0.quality == quality }
            if group.contains(where: { $0.id == systemDefault }) {
                #expect(group.first?.id == systemDefault)
            }
            let names = group.filter { $0.id != systemDefault }.map(\.name)
            #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        }
    }

    @Test func qualitiesOrderFromStandardToPremium() {
        #expect(VoiceOption.Quality.standard < .enhanced)
        #expect(VoiceOption.Quality.enhanced < .premium)
        let option = VoiceOption(id: "voice.id", name: "Ava", quality: .premium)
        #expect(option.id == "voice.id")
        #expect(option.name == "Ava")
        #expect(option.quality == .premium)
    }
}
