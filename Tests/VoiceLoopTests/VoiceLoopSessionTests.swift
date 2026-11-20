import AVFoundation
import Foundation
import Observation
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

/// The pitch shift that speech plays through in `engine`.
@MainActor
private func pitchShift(in engine: AVAudioEngine?) throws -> AVAudioUnitTimePitch {
    let shifts = try #require(engine).attachedNodes.compactMap { $0 as? AVAudioUnitTimePitch }
    #expect(shifts.count == 1)
    return try #require(shifts.first)
}

/// Lets queued main-actor work and the audio engine run for a moment, before checking that
/// something did NOT happen.
private func settle(_ duration: Duration = .milliseconds(250)) async throws {
    try await Task.sleep(for: duration)
}

/// Waits while the sound of speech that was just cut off dies away. A stopped player's sound runs
/// on for two render passes: the pitch shift holds one pass of it, then the engine fades it out.
/// Waits for twice that, counted in passes, not time. Whether they were rendered.
@MainActor
private func cutOffSpeechDiesAway(on bed: VoiceTestBed) async -> Bool {
    await renderPassesGoBy(4, on: bed)
}

/// Whether the loop kept `engine` running for at least the whole stop cue after `stopped`, when
/// the test called `stop()`. By the clock, which the loop's teardown timer runs on and which never
/// runs fast; the tests render the cue themselves, so its frames can't show how long it was kept.
@MainActor
private func keptRunningThroughTheStopCue(_ engine: AVAudioEngine, since stopped: ContinuousClock.Instant) -> Bool {
    let cue = Duration.seconds(Double(SoundCue.listeningStopped.samples(sampleRate: 48_000).count) / 48_000)
    guard let engineStopped = (engine as? OfflineEngine)?.lastStopped else { return false }
    return engineStopped - stopped >= cue
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

    @Test func anEngineThatStopsWhileTheRecognizerStartsIsStartedAgain() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        // The hardware changes before anything is watching for it.
        bed.whenRecognizerStarts = { bed.audio.engines.last?.stop() }

        try await loop.start()
        defer { loop.stop() }

        #expect(loop.state == .listening(partial: ""))
        #expect(bed.audio.engines.count == 1)
        #expect(bed.audio.engines.last?.isRunning == true)
        #expect(bed.recognizers.count == 1)
        #expect(bed.recognizer.isStarted && !bed.recognizer.isCancelled)
    }
}

// MARK: - Listening

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ListeningTests {
    @Test func whatIsHeardShowsAsTheLiveTranscriptAndIsSentAfterAPause() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        // Long until the final result is in: a short pause could end the utterance at the
        // partial "Mark that" before the final arrives.
        loop.pauseThreshold = .seconds(30)
        try await loop.start()
        defer { loop.stop() }
        #expect(loop.state == .listening(partial: ""))

        bed.recognizer.hear("Mark that", over: 0...0.5)
        #expect(await eventually { loop.state == .listening(partial: "Mark that") })
        bed.recognizer.hear("Mark that read.", over: 0...1, isFinal: true, alternatives: ["Mark that red."])
        #expect(await eventually { loop.state == .listening(partial: "Mark that read.") })
        loop.pauseThreshold = .milliseconds(50)

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
        // voice this utterance would be sent after 0.5 s, and with it after 2 s at most.
        loop.pauseThreshold = .milliseconds(500)
        try await loop.start()
        defer { loop.stop() }
        let sent = UtteranceLog(loop)

        bed.audio.isVoicePresent = true
        bed.recognizer.hear("Hello there.", over: 0...1)
        try await settle(.milliseconds(1100))
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
        #expect(await lastPassPlays(on: bed))
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

        // The same words make the same sound each time, give or take the synthesizer.
        #expect(firstAlone > 0)
        #expect(secondAlone > firstAlone)
        #expect(abs(together - (firstAlone + secondAlone)) <= (firstAlone + secondAlone) / 20)
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
        #expect(await cutOffSpeechDiesAway(on: bed))
        let playedWhenStopped = bed.audio.playedFrames
        // Nothing more plays, neither the rest of the reply nor the queued one, through many
        // more passes.
        try await settle()
        #expect(await renderPassesGoBy(20, on: bed))
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
        #expect(await lastPassPlays(on: bed))
        // Only the preview played after that: neither long reply carried on.
        #expect(abs(bed.audio.playedFrames - playedBeforePreview - previewAlone) <= previewAlone / 4)
    }

    /// Previews `text` while the loop is off and waits until it has played. Returns how much
    /// sound came out of the speaker.
    private func framesPlayed(previewing text: String, by loop: VoiceLoop, on bed: VoiceTestBed) async throws -> Int {
        let before = bed.audio.playedFrames
        loop.preview(text)
        let engine = try #require(bed.audio.engines.last)
        #expect(await eventually { !engine.isRunning })
        return bed.audio.playedFrames - before
    }

    @Test func aVoicePreviewWhileOffPlaysOnAnEngineOfItsOwnAtTheChosenPitch() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        loop.speechPitch = VoiceLoop.speechPitches.upperBound

        loop.preview("Hi.")

        #expect(loop.state == .off)
        #expect(bed.audio.engines.count == 1)
        let engine = try #require(bed.audio.engines.first)
        let shift = try pitchShift(in: engine)
        #expect(shift.pitch == 1200)
        #expect(!shift.bypass)
        #expect(await eventually { bed.audio.playedFrames > 0 })
        // Its engine stops once it has played.
        #expect(await eventually { !engine.isRunning })
        #expect(loop.state == .off)
    }

    @Test func aNewVoicePreviewCutsOffTheOneBefore() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        let previewAlone = try await framesPlayed(previewing: "Hi.", by: loop, on: bed)

        loop.preview(longReply)
        #expect(await eventually { bed.audio.playedFrames > previewAlone })
        let first = try #require(bed.audio.engines.last)
        let playedBeforeSecond = bed.audio.playedFrames
        let second = try await framesPlayed(previewing: "Hi.", by: loop, on: bed)

        #expect(!first.isRunning)
        // Only the second preview played after that: the long one didn't carry on.
        #expect(previewAlone > 0)
        #expect(abs(bed.audio.playedFrames - playedBeforeSecond - previewAlone) <= previewAlone / 4)
        #expect(abs(second - previewAlone) <= previewAlone / 4)
    }

    @Test func startingStopsAVoicePreviewAndListensAsUsual() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        loop.preview(longReply)
        #expect(await eventually { bed.audio.playedFrames > 0 })
        let previewEngine = try #require(bed.audio.engines.last)
        // Starting stops the preview's engine before anything more renders, so none of the
        // preview plays from here on.
        let playedWhenStarted = bed.audio.playedFrames

        try await loop.start()
        defer { loop.stop() }

        #expect(!previewEngine.isRunning)
        #expect(loop.state == .listening(partial: ""))
        #expect(bed.audio.engines.count == 2)
        // Nothing more of the preview plays, through many passes of the new engine.
        try await settle()
        #expect(await renderPassesGoBy(20, on: bed))
        #expect(bed.audio.playedFrames == playedWhenStarted)
    }

    @Test func anUnknownVoiceFallsBackToAnInstalledOne() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        loop.voiceIdentifier = "com.example.no-such-voice"
        #expect(await framesPlayed(saying: ["Hi."], by: loop, on: bed) > 0)

        loop.voiceIdentifier = try #require(loop.voices.last { $0.engine == .system }?.id)
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

        // The reply is cut off as the words show, so its sound dies away from there.
        #expect(await eventually { loop.state == .listening(partial: "Wait.") })
        #expect(await cutOffSpeechDiesAway(on: bed))
        let playedWhenInterrupted = bed.audio.playedFrames
        #expect(await nextUtterance(of: loop)?.text == "Wait.")

        // The interrupted reply and the queued one are both gone, through many passes.
        try await settle()
        #expect(await renderPassesGoBy(20, on: bed))
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

    @Test func withoutEchoCancellationTalkingOverAReplyDoesNotInterruptIt() async throws {
        let bed = VoiceTestBed()
        bed.hasVoiceProcessing = false
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        loop.speak(longReply)
        #expect(await eventually { bed.audio.playedFrames > 0 })
        // It could be the user, or the reply itself reaching the microphone: there is no telling.
        bed.recognizer.hear("Wait stop that", over: later)
        try await settle(.milliseconds(100))

        #expect(loop.state == .speaking)
        let playedSoFar = bed.audio.playedFrames
        #expect(await eventually { bed.audio.playedFrames > playedSoFar })

        // Only the stop button interrupts.
        loop.stopSpeaking()
        #expect(loop.state == .listening(partial: ""))
    }

    @Test func withoutEchoCancellationAReplysEchoIsNotSentAfterwards() async throws {
        let bed = VoiceTestBed()
        bed.hasVoiceProcessing = false
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        let sent = UtteranceLog(loop)

        loop.speak("Hi there.")
        // The microphone hears the reply itself.
        bed.recognizer.hear("Hi there", over: 0...0.5)
        #expect(await eventually { loop.state == .listening(partial: "") })

        // The echo's final result arrives after the reply has ended.
        bed.recognizer.hear("Hi there.", over: 0...0.5, isFinal: true)
        try await settle()
        #expect(loop.state == .listening(partial: ""))
        #expect(sent.texts.isEmpty)

        bed.recognizer.hear("Hello.", over: later, isFinal: true)
        #expect(await eventually { sent.texts == ["Hello."] })
    }
}

// MARK: - The engine stopping itself

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct EngineStopTests {
    /// The audio hardware's configuration changed while the devices stayed the same, as on the
    /// iPhone right after a new engine starts: the engine stops itself and says so.
    private func stopByItself(_ engine: AVAudioEngine) {
        engine.stop()
        postConfigurationChange(for: engine)
    }

    @Test func anEngineThatStopsByItselfIsStartedAgainWithTheUtteranceInProgressKept() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        // Long enough that the utterance is still open after the engine is back.
        loop.pauseThreshold = .seconds(30)
        try await loop.start()
        defer { loop.stop() }
        let engine = try #require(bed.audio.engines.last)
        bed.recognizer.hear("Mark that", over: 0...0.5)
        #expect(await eventually { loop.state == .listening(partial: "Mark that") })

        stopByItself(engine)

        // The same engine and the same recognizer carry on.
        #expect(await eventually { engine.isRunning })
        #expect(bed.audio.engines.count == 1)
        #expect(bed.recognizers.count == 1)
        #expect(!bed.recognizer.isCancelled)
        #expect(loop.state == .listening(partial: "Mark that"))

        bed.recognizer.hear("Mark that read.", over: 0...1, isFinal: true)
        #expect(await eventually { loop.state == .listening(partial: "Mark that read.") })
        // Shortened only now: before the final arrives, "Mark that" has long been unchanged,
        // so a short pause could end the utterance there.
        loop.pauseThreshold = .milliseconds(50)
        #expect(await nextUtterance(of: loop)?.text == "Mark that read.")
    }

    @Test func aReplyBeingSpokenStartsOverWhenTheEngineIsStartedAgain() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        let engine = try #require(bed.audio.engines.last)
        let reply = "Hi there, how are you doing today?"
        loop.speak(reply)
        #expect(await eventually { loop.state == .listening(partial: "") })
        let wholeReply = bed.audio.playedFrames

        loop.speak(reply)
        #expect(await eventually { bed.audio.playedFrames > wholeReply + wholeReply / 5 })
        stopByItself(engine)

        #expect(await eventually { engine.isRunning && loop.state == .speaking })
        #expect(await eventually { loop.state == .listening(partial: "") })
        // The part played before the stop, then the whole reply again.
        let secondTime = bed.audio.playedFrames - wholeReply
        #expect(secondTime > wholeReply + wholeReply / 10)
        #expect(bed.audio.engines.count == 1)
    }

    @Test func aReplyAfterTheEngineIsStartedAgainFollowingOneThatPlayedToItsEndIsSpoken() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        let engine = try #require(bed.audio.engines.last)
        let reply = "Hi there, how are you doing today?"
        loop.speak(reply)
        #expect(await eventually { loop.state == .listening(partial: "") })
        let wholeReply = bed.audio.playedFrames

        // Nothing is being said when the engine stops.
        stopByItself(engine)
        #expect(await eventually { engine.isRunning })

        loop.speak(reply)
        #expect(loop.state == .speaking)
        #expect(await eventually { loop.state == .listening(partial: "") })
        #expect(bed.audio.playedFrames > wholeReply + wholeReply / 2)
        #expect(bed.audio.engines.count == 1)
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
        #expect(engine.isRunning)
        #expect(loop.state == .listening(partial: ""))
    }

    @Test func anEngineThatKeepsStoppingTurnsTheLoopOffAndTheNextStartCountsAfresh() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        let engine = try #require(bed.audio.engines.last)

        // Three stops in a row are each recovered from.
        for _ in 0..<3 {
            stopByItself(engine)
            #expect(await eventually { engine.isRunning })
            #expect(loop.state == .listening(partial: ""))
        }
        // A fourth within ten seconds isn't: starting it again won't help.
        stopByItself(engine)

        #expect(await eventually { loop.state == .off })
        #expect(!engine.isRunning)
        #expect(await eventually { bed.recognizer.isCancelled })

        try await loop.start()
        defer { loop.stop() }
        let next = try #require(bed.audio.engines.last)
        stopByItself(next)
        #expect(await eventually { next.isRunning })
        #expect(loop.state == .listening(partial: ""))
    }

    @Test func anEngineThatCannotBeStartedAgainIsReplacedAndListeningCarriesOn() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        let first = try #require(bed.audio.engines.last)

        try bed.audio.breakEngine(first)
        postConfigurationChange(for: first)

        #expect(await eventually { bed.recognizers.count == 2 && bed.recognizer.isStarted })
        #expect(loop.state == .listening(partial: ""))
        #expect(bed.audio.engines.count == 2)
        #expect(bed.audio.engines.last?.isRunning == true)
        #expect(bed.recognizers.first?.isCancelled == true)

        bed.recognizer.hear("Still here.", over: 0...1, isFinal: true)
        #expect(await nextUtterance(of: loop)?.text == "Still here.")
    }

    @Test func aReplyCutOffWhenTheEngineIsReplacedIsSpokenAgain() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        let first = try #require(bed.audio.engines.last)

        loop.speak("Hi there, how are you doing today?")
        #expect(await eventually { bed.audio.playedFrames > 0 })
        try bed.audio.breakEngine(first)
        postConfigurationChange(for: first)

        // The new engine says it again.
        #expect(await eventually { bed.audio.engines.count == 2 && loop.state == .speaking })
        let playedBeforeRebuild = bed.audio.playedFrames
        #expect(await eventually { bed.audio.playedFrames > playedBeforeRebuild })
        #expect(bed.audio.engines.last?.isRunning == true)
    }

    @Test func whenTheEngineCannotBeReplacedTheLoopTurnsOff() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        let first = try #require(bed.audio.engines.last)

        bed.permissionError = .microphonePermissionDenied
        try bed.audio.breakEngine(first)
        postConfigurationChange(for: first)

        #expect(await eventually { loop.state == .off })
        #expect(bed.audio.engines.count == 1)
    }
}

// MARK: - Speaking speed and other apps' audio

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct VoiceSettingsTests {
    /// How much sound the loop makes saying `text` at `rate`.
    private func framesPlayed(saying text: String, atRate rate: Float, by loop: VoiceLoop, on bed: VoiceTestBed) async -> Int {
        let before = bed.audio.playedFrames
        loop.speechRate = rate
        loop.speak(text)
        #expect(loop.state == .speaking)
        #expect(await eventually { loop.state == .listening(partial: "") })
        #expect(await lastPassPlays(on: bed))
        return bed.audio.playedFrames - before
    }

    @Test func aFasterSpeechRateSaysTheSameWordsInLessTime() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        #expect(loop.speechRate == VoiceLoop.defaultSpeechRate)
        #expect(VoiceLoop.speechRates.contains(VoiceLoop.defaultSpeechRate))
        let text = "One, two, three."

        let slow = await framesPlayed(saying: text, atRate: VoiceLoop.speechRates.lowerBound, by: loop, on: bed)
        let normal = await framesPlayed(saying: text, atRate: VoiceLoop.defaultSpeechRate, by: loop, on: bed)
        let fast = await framesPlayed(saying: text, atRate: VoiceLoop.speechRates.upperBound, by: loop, on: bed)

        #expect(fast > 0)
        #expect(fast < normal)
        #expect(normal < slow)
    }

    /// How much sound the loop makes saying `text` at `pitch`.
    private func framesPlayed(saying text: String, atPitch pitch: Float, by loop: VoiceLoop, on bed: VoiceTestBed) async -> Int {
        let before = bed.audio.playedFrames
        loop.speechPitch = pitch
        loop.speak(text)
        #expect(loop.state == .speaking)
        #expect(await eventually { loop.state == .listening(partial: "") })
        #expect(await lastPassPlays(on: bed))
        return bed.audio.playedFrames - before
    }

    @Test func eachReplyIsShiftedToThePitchSetWhenItStarts() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        let shift = try pitchShift(in: bed.audio.engines.last)
        #expect(loop.speechPitch == VoiceLoop.defaultSpeechPitch)
        #expect(VoiceLoop.speechPitches.contains(VoiceLoop.defaultSpeechPitch))
        // At normal pitch the voice plays as the synthesizer made it.
        #expect(shift.bypass)

        // Not right away: the next reply takes it.
        loop.speechPitch = VoiceLoop.speechPitches.upperBound
        #expect(shift.bypass)

        #expect(await framesPlayed(saying: "Hi.", atPitch: VoiceLoop.speechPitches.upperBound, by: loop, on: bed) > 0)
        #expect(shift.pitch == 1200)
        #expect(!shift.bypass)

        #expect(await framesPlayed(saying: "Hi.", atPitch: VoiceLoop.speechPitches.lowerBound, by: loop, on: bed) > 0)
        #expect(shift.pitch == -1200)
        #expect(!shift.bypass)

        #expect(await framesPlayed(saying: "Hi.", atPitch: VoiceLoop.defaultSpeechPitch, by: loop, on: bed) > 0)
        #expect(shift.bypass)
    }

    @Test func aShiftedReplyTakesAsLongAsAnUnshiftedOne() async throws {
        let bed = VoiceTestBed()
        // Pulled 512 frames a pass, nearer what a device's audio hardware pulls, not 4096. At 4096
        // frames every 2 ms the engine outruns the synthesizer: the player runs dry mid-reply and
        // the shift smears sound into each gap, so a shifted reply's count jumped by up to 4,650
        // frames from one run to the next. At 512 it stays within 1,400 of the unshifted one.
        bed.audio.framesPerPass = 512
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        let text = "One, two, three."

        let normal = await framesPlayed(saying: text, atPitch: VoiceLoop.defaultSpeechPitch, by: loop, on: bed)
        let high = await framesPlayed(saying: text, atPitch: VoiceLoop.speechPitches.upperBound, by: loop, on: bed)
        let low = await framesPlayed(saying: text, atPitch: VoiceLoop.speechPitches.lowerBound, by: loop, on: bed)

        // The shift keeps the speed, and every word is played. Its overlapping windows smear a
        // little sound into the gaps between words (about 1-3% more here).
        #expect(normal > 0)
        #expect(abs(high - normal) <= normal / 20)
        #expect(abs(low - normal) <= normal / 20)
    }

    @Test func aRebuiltEngineShiftsRepliesToo() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        loop.speechPitch = VoiceLoop.speechPitches.upperBound

        loop.pausesOtherAudio = false
        #expect(await eventually { bed.recognizers.count == 2 && bed.recognizer.isStarted })
        let before = bed.audio.playedFrames
        loop.speak("Hi.")

        // Spoken on the new engine: the reply waits in the queue if that is still starting.
        #expect(await eventually { bed.audio.playedFrames > before })
        #expect(bed.audio.engines.count == 2)
        #expect(try pitchShift(in: bed.audio.engines.last).pitch == 1200)
    }

    // What the setting does to other apps' audio can't be seen here: the offline engine has no
    // voice processing to duck with, and macOS has no audio session. The iOS half (the session
    // mixing with others) is checked in VoiceLoopInterruptionTests. These check when it applies.

    @Test func changingPauseOtherAudioWhileOffRebuildsNothing() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        #expect(loop.pausesOtherAudio)

        loop.pausesOtherAudio = false
        try await settle()
        #expect(loop.state == .off)
        #expect(bed.audio.engines.isEmpty)

        // The next start is an ordinary one.
        try await loop.start()
        defer { loop.stop() }
        #expect(loop.state == .listening(partial: ""))
        #expect(bed.audio.engines.count == 1)
        #expect(bed.recognizers.count == 1)
    }

    @Test func changingPauseOtherAudioWhileListeningRebuildsTheEngineToApplyIt() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        let first = try #require(bed.audio.engines.last)

        loop.pausesOtherAudio = false

        // Voice mode stays on through the rebuild.
        #expect(loop.state == .listening(partial: ""))
        #expect(!first.isRunning)
        #expect(await eventually { bed.recognizers.count == 2 && bed.recognizer.isStarted })
        let second = try #require(bed.audio.engines.last)
        #expect(bed.audio.engines.count == 2)
        #expect(second.isRunning)
        #expect(bed.recognizers.first?.isCancelled == true)

        // The same value again changes nothing.
        loop.pausesOtherAudio = false
        try await settle()
        #expect(bed.audio.engines.count == 2)
        #expect(bed.recognizers.count == 2)
    }

    @Test func aReplyBeingSpokenWhenPauseOtherAudioChangesIsSpokenAgainAfterTheRebuild() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        loop.speak("Hi there, how are you doing today?")
        #expect(await eventually { bed.audio.playedFrames > 0 })
        loop.pausesOtherAudio = false

        // Cut off by the rebuild, then said again on the new engine.
        #expect(loop.state == .listening(partial: ""))
        #expect(await eventually { bed.audio.engines.count == 2 && loop.state == .speaking })
        let playedBeforeRebuild = bed.audio.playedFrames
        #expect(await eventually { bed.audio.playedFrames > playedBeforeRebuild })
    }

    @Test func stoppingRightAfterASettingsRebuildBeginsLeavesTheLoopOff() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)

        // The rebuild's new start is queued; the stop comes before it runs.
        loop.pausesOtherAudio = false
        loop.stop()
        try await settle()

        #expect(loop.state == .off)
        #expect(bed.recognizers.count == 1)
        #expect(bed.audio.engines.count == 1)
    }

    @Test func theSystemVoicesAreListedOnceAndAgainWhenTheyOrTheLanguageChange() async throws {
        let bed = VoiceTestBed()
        let samantha = VoiceOption(id: "voice.samantha", name: "Samantha", quality: .standard)
        let ava = VoiceOption(id: "voice.ava", name: "Ava", quality: .premium)
        bed.systemVoices = [samantha]
        let loop = bed.makeLoop()
        loop.voiceIdentifier = samantha.id

        // A voice picker reads the choice once for every voice it lists.
        for _ in 0..<50 {
            #expect(loop.chosenVoice == samantha)
        }
        #expect(loop.voices.filter { $0.engine == .system } == [samantha])
        #expect(bed.systemVoiceListings == ["en-US"])

        // A voice is installed: settings is told, and the new list is read.
        let changed = ChangeFlag()
        withObservationTracking {
            _ = loop.voices
        } onChange: {
            MainActor.assumeIsolated { changed.isSet = true }
        }
        bed.systemVoices = [ava, samantha]
        NotificationCenter.default.post(name: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil)
        #expect(await eventually { changed.isSet })
        #expect(loop.voices.filter { $0.engine == .system } == [ava, samantha])
        #expect(bed.systemVoiceListings == ["en-US", "en-US"])

        // Another language has voices of its own.
        bed.languageCode = "en-GB"
        _ = loop.voices
        #expect(bed.systemVoiceListings == ["en-US", "en-US", "en-GB"])
    }
}

/// Set when an observed value changes.
@MainActor
private final class ChangeFlag {
    var isSet = false
}

// MARK: - Sound cues

// The other suites leave the cues off, so that what plays is only what is said. These turn
// them on. `cuesPlayOut(on:)` lets a cue finish, however long the machine takes to render it.

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SoundCueTests {
    @Test func startingPlaysTheStartCueWithoutSpeaking() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop(soundCues: true)

        try await loop.start()
        defer { loop.stop() }

        #expect(loop.state == .listening(partial: ""))
        #expect(await eventually { bed.audio.playedFrames > 0 })
        #expect(loop.state == .listening(partial: ""))
    }

    @Test func aReactionCuePlaysWhileListeningAndNotWhileOff() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop(soundCues: true)

        loop.play(.reaction)
        try await settle()
        #expect(loop.state == .off)
        #expect(bed.audio.engines.isEmpty)
        #expect(bed.audio.playedFrames == 0)

        try await loop.start()
        defer { loop.stop() }
        #expect(await cuesPlayOut(on: bed))
        let played = bed.audio.playedFrames
        loop.play(.reaction)

        #expect(loop.state == .listening(partial: ""))
        #expect(await eventually { bed.audio.playedFrames > played })
        #expect(loop.state == .listening(partial: ""))
    }

    @Test func stoppingTurnsTheLoopOffAtOnceThenPlaysTheStopCueAndReleasesTheEngine() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop(soundCues: true)
        try await loop.start()
        let engine = try #require(bed.audio.engines.last)
        #expect(await cuesPlayOut(on: bed))
        let startCue = bed.audio.playedFrames
        #expect(startCue > 0)

        let stopped = ContinuousClock.now
        loop.stop()

        // Listening ends at once; the engine runs on only to play the stop cue.
        #expect(loop.state == .off)
        #expect(engine.isRunning)
        // The stop cue (170 ms, two passes) renders now, before an await lets the engine's
        // teardown timer run: however slow the machine, the cue has played before the engine stops.
        bed.audio.render(passes: 4)
        #expect(await eventually { bed.recognizer.isCancelled })
        #expect(await eventually { !engine.isRunning })
        #expect(keptRunningThroughTheStopCue(engine, since: stopped))
        // The whole stop cue played: the same taps as the start cue, in the other order.
        let played = bed.audio.playedFrames
        #expect(abs(played - 2 * startCue) <= startCue / 10)
        try await settle()
        #expect(bed.audio.playedFrames == played)
        #expect(loop.state == .off)
    }

    @Test func startingWhileTheStopCuePlaysEndsItAndLeavesOneEngineRunning() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop(soundCues: true)
        try await loop.start()
        let first = try #require(bed.audio.engines.last)
        loop.stop()
        #expect(first.isRunning)

        try await loop.start()
        defer { loop.stop() }

        #expect(loop.state == .listening(partial: ""))
        #expect(!first.isRunning)
        #expect(bed.audio.engines.count == 2)
        #expect(bed.audio.engines.filter(\.isRunning).count == 1)
        // Well after the stop cue would have ended: its timer leaves the new engine alone.
        try await settle(.milliseconds(600))
        #expect(loop.state == .listening(partial: ""))
        #expect(bed.audio.engines.last?.isRunning == true)
        #expect(bed.audio.engines.filter(\.isRunning).count == 1)
    }

    @Test func aCueCutOffWhenTheEngineStopsByItselfPlaysAgainInFull() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop(soundCues: true)
        try await loop.start()
        defer { loop.stop() }
        let engine = try #require(bed.audio.engines.last)

        // As on the iPhone, the new engine stops by itself before the start cue has finished.
        engine.stop()
        let playedBeforeStop = bed.audio.playedFrames
        // Lets the loop start watching for configuration changes; the stopped engine plays nothing meanwhile.
        try await settle(.milliseconds(50))
        postConfigurationChange(for: engine)

        #expect(await eventually { engine.isRunning })
        #expect(await eventually { bed.audio.playedFrames > playedBeforeStop })
        #expect(await cuesPlayOut(on: bed))
        let playedAfterRestart = bed.audio.playedFrames - playedBeforeStop
        // One whole start cue, for comparison.
        let playedBeforeAnother = bed.audio.playedFrames
        loop.play(.listeningStarted)
        #expect(await eventually { bed.audio.playedFrames > playedBeforeAnother })
        #expect(await cuesPlayOut(on: bed))
        let wholeCue = bed.audio.playedFrames - playedBeforeAnother

        #expect(abs(playedAfterRestart - wholeCue) <= wholeCue / 10)
        #expect(bed.audio.engines.count == 1)
        #expect(loop.state == .listening(partial: ""))
    }

    @Test func aRebuiltEngineEndsTheOldOneAtOnceAndPlaysTheStartCueAgain() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop(soundCues: true)
        try await loop.start()
        defer { loop.stop() }
        let first = try #require(bed.audio.engines.last)
        #expect(await cuesPlayOut(on: bed))
        let played = bed.audio.playedFrames

        loop.pausesOtherAudio = false

        // A rebuild isn't a stop: the old engine plays no stop cue.
        #expect(!first.isRunning)
        #expect(loop.state == .listening(partial: ""))
        #expect(await eventually { bed.audio.engines.count == 2 && bed.recognizer.isStarted })
        #expect(await eventually { bed.audio.playedFrames > played })
    }
}

// MARK: - Audio devices changing

/// The built-in microphone and speaker, the test bed's devices unless a test changes them.
private let builtIn = VoiceTestBed.builtInDevices

/// AirPods, as the iOS route names them during a call: microphone and output both.
private let airPods = AudioDevices(
    inputs: [.init(id: "airpods-hfp", kind: "BluetoothHFP")],
    outputs: [.init(id: "airpods-hfp", kind: "BluetoothHFP")]
)

/// Whether as much sound as one whole stop cue has come out since `played`.
@MainActor
private func playedOneStopCue(on bed: VoiceTestBed, since played: Int) -> Bool {
    let expected = soundingFrames(of: .listeningStopped)
    return abs(bed.audio.playedFrames - played - expected) <= expected / 10
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct AudioDeviceChangeTests {
    @Test func aDeviceComingEndsVoiceModeAndTheStopCuePlaysOnAnEngineOfItsOwn() async throws {
        let bed = VoiceTestBed()
        let loop = try await listeningLoopWithCues(on: bed)
        let engine = try #require(bed.audio.engines.last)
        let played = bed.audio.playedFrames

        // AirPods connect.
        bed.reportRouteChange(isDeviceChange: true, from: builtIn, to: airPods)

        #expect(await eventually { loop.state == .off })
        // The loop's engine stops at once, without its stop cue; another, which only plays,
        // plays it and then stops.
        #expect(!engine.isRunning)
        #expect(bed.audio.engines.count == 2)
        #expect(await eventually { bed.audio.engines.allSatisfy { !$0.isRunning } })
        #expect(await eventually { bed.recognizer.isCancelled })
        #expect(playedOneStopCue(on: bed, since: played))
        // It doesn't start again.
        try await settle()
        #expect(loop.state == .off)
        #expect(bed.recognizers.count == 1)
        #expect(bed.audio.engines.count == 2)
    }

    @Test func withPushToTalkADeviceChangePlaysTheStopCueToo() async throws {
        let bed = VoiceTestBed()
        let loop = try await pushToTalkLoop(on: bed, soundCues: true)
        let played = bed.audio.playedFrames

        bed.reportRouteChange(isDeviceChange: true, from: builtIn, to: airPods)

        #expect(await eventually { loop.state == .off })
        #expect(await eventually { bed.audio.engines.allSatisfy { !$0.isRunning } })
        #expect(playedOneStopCue(on: bed, since: played))
    }

    @Test func anOverrideThenADeviceArrivingBackToBackEndsVoiceMode() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        let receiver = AudioDevices(
            inputs: builtIn.inputs,
            outputs: [.init(id: "built-in-receiver", kind: "Receiver")]
        )

        // Both before the loop handles either: the speaker override, then AirPods connecting.
        bed.reportRouteChange(isDeviceChange: false, from: receiver, to: builtIn)
        bed.reportRouteChange(isDeviceChange: true, from: builtIn, to: airPods)

        #expect(await eventually { loop.state == .off })
    }

    @Test func aRouteChangeThatIsNotADeviceOrLeavesTheDevicesAloneKeepsListening() async throws {
        let bed = VoiceTestBed()
        let loop = try await listeningLoopWithCues(on: bed)
        defer { loop.stop() }
        let engine = try #require(bed.audio.engines.last)
        let airPodsForMusic = AudioDevices(
            inputs: builtIn.inputs,
            outputs: [.init(id: "airpods-a2dp", kind: "BluetoothA2DPOutput")]
        )

        // The AirPods move to their call profile after the start, with ports of their own: not
        // a device coming or going.
        bed.reportRouteChange(isDeviceChange: false, from: airPodsForMusic, to: airPods)
        // A device came or went, but the route's devices are the same on both sides.
        bed.reportRouteChange(isDeviceChange: true, from: airPods, to: airPods)
        postConfigurationChange(for: engine)

        #expect(await staysSilent(on: bed))
        #expect(loop.state == .listening(partial: ""))
        #expect(engine.isRunning)
        #expect(!bed.recognizer.isCancelled)
        #expect(bed.audio.engines.count == 1)
    }

    #if os(macOS)
    @Test func newDefaultDevicesEndVoiceModeWhenTheEngineSaysItsConfigurationChanged() async throws {
        let bed = VoiceTestBed()
        bed.audioDevices = airPods
        let loop = try await listeningLoopWithCues(on: bed)
        let engine = try #require(bed.audio.engines.last)
        let played = bed.audio.playedFrames

        // AirPods are taken out, as on the Mac: the engine stops by itself and says so, with no
        // route change to say why.
        bed.audioDevices = builtIn
        engine.stop()
        postConfigurationChange(for: engine)

        #expect(await eventually { loop.state == .off })
        #expect(await eventually { bed.audio.engines.allSatisfy { !$0.isRunning } })
        #expect(await eventually { bed.recognizer.isCancelled })
        #expect(playedOneStopCue(on: bed, since: played))
        // The loop's engine wasn't started again: the stop cue played on another.
        #expect(bed.audio.engines.count == 2)
    }

    @Test func newDefaultDevicesEndVoiceModeWithNoNotificationAtAll() async throws {
        let bed = VoiceTestBed()
        let loop = try await listeningLoopWithCues(on: bed)
        let engine = try #require(bed.audio.engines.last)
        let played = bed.audio.playedFrames

        // The default output moves to AirPods of the same format: the engine carries on, and
        // nothing says so.
        bed.audioDevices = airPods

        #expect(await eventually { loop.state == .off })
        #expect(!engine.isRunning)
        #expect(await eventually { bed.audio.engines.allSatisfy { !$0.isRunning } })
        #expect(playedOneStopCue(on: bed, since: played))
    }

    @Test func aRebuildDoesNotTakeUpNewDevices() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        let first = try #require(bed.audio.engines.last)

        // The default output changes. The engine says its configuration changed while the old
        // devices still show, and can't start again; the new ones show while it is rebuilt.
        bed.whenRecognizerStarts = { bed.audioDevices = airPods }
        try bed.audio.breakEngine(first)
        postConfigurationChange(for: first)

        #expect(await eventually { loop.state == .off })
        #expect(bed.recognizers.count == 2)
        #expect(await eventually { bed.recognizer.isCancelled })
        #expect(await eventually { bed.audio.engines.allSatisfy { !$0.isRunning } })
        try await settle()
        #expect(loop.state == .off)
        #expect(bed.recognizers.count == 2)
    }
    #endif

    #if os(iOS)
    @Test func onIOSAConfigurationChangeAloneKeepsListeningAndOnlyADeviceRouteChangeStops() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        let engine = try #require(bed.audio.engines.last)

        // AirPods connect: the engine stops by itself and says so before the route change comes.
        bed.audioDevices = airPods
        engine.stop()
        postConfigurationChange(for: engine)

        // Started again: on iOS only the route change can end voice mode.
        #expect(await eventually { engine.isRunning })
        try await settle()
        #expect(loop.state == .listening(partial: ""))

        bed.reportRouteChange(isDeviceChange: true, from: builtIn, to: airPods)

        #expect(await eventually { loop.state == .off })
    }
    #endif
}

// MARK: - Working cue

// The low taps that play once when the bot starts working on a reply. These tests check that
// they don't repeat by letting seconds of audio go by, measured by the microphone audio the
// recognizer has been fed: the offline engine renders far faster than real time.

/// Seconds of microphone audio the current recognizer has been fed: how far the engine has run.
@MainActor
private func heardSeconds(_ bed: VoiceTestBed) -> Double {
    Double(bed.recognizer.heardFrames) / bed.recognizer.audioFormat.sampleRate
}

/// How much sound one whole `cue` adds to `OfflineAudio.playedFrames`: the engine renders at the
/// cues' own 48 kHz.
private func soundingFrames(of cue: SoundCue) -> Int {
    cue.samples(sampleRate: 48_000).count { abs($0) >= 0.001 }
}

/// Waits while `seconds` of audio go by, long after a cue would have ended. Whether they did.
@MainActor
private func audioGoesBy(_ seconds: Double = 2, on bed: VoiceTestBed) async -> Bool {
    let start = heardSeconds(bed)
    return await eventually { heardSeconds(bed) > start + seconds }
}

/// Whether the loop makes as much sound as `cue` once, and no more, while `seconds` of audio go
/// by.
@MainActor
private func playsOnce(_ cue: SoundCue, on bed: VoiceTestBed, within seconds: Double = 3) async -> Bool {
    let played = bed.audio.playedFrames
    guard await audioGoesBy(seconds, on: bed) else { return false }
    let expected = soundingFrames(of: cue)
    return abs(bed.audio.playedFrames - played - expected) <= expected / 10
}

/// Whether the loop makes no sound while `seconds` of audio go by.
@MainActor
private func staysSilent(on bed: VoiceTestBed, for seconds: Double = 2) async -> Bool {
    let played = bed.audio.playedFrames
    guard await audioGoesBy(seconds, on: bed) else { return false }
    return bed.audio.playedFrames == played
}

/// A loop with the sound cues on, listening, once its start cue has played.
@MainActor
private func listeningLoopWithCues(on bed: VoiceTestBed) async throws -> VoiceLoop {
    let loop = bed.makeLoop(soundCues: true)
    try await loop.start()
    #expect(await cuesPlayOut(on: bed))
    return loop
}

/// A loop as `listeningLoopWithCues(on:)` gives, speaking with a Kokoro voice, with what comes out
/// of the speaker recorded in `OfflineAudio.output`. `FakeKokoro` renders every sentence as the
/// same tone, so a reply sounds the same each time it is said, and a test can find it there.
@MainActor
private func recordingKokoroLoopWithCues(on bed: VoiceTestBed) async throws -> VoiceLoop {
    bed.audio.recordsOutput = true
    let loop = try await listeningLoopWithCues(on: bed)
    loop.voiceIdentifier = "kokoro.af_heart"
    #expect(await eventually { loop.kokoroModelState == .ready })
    return loop
}

/// A stretch of sound out of the speaker, in `OfflineAudio.output`, with no silence longer than
/// 5 ms in it.
private struct Sound {
    /// Where its first and last sounding samples are, in the output looked at.
    var first: Int
    var last: Int
    /// How many of its samples the speaker's meter counts as sound (`OfflineAudio.playedFrames`).
    var frames: Int
    /// Its loudest sample.
    var peak: Float

    /// Whether it is no louder than the working taps, which peak at about 0.03. Everything else
    /// these tests play is far louder: `FakeKokoro`'s tone at 0.25, the other cues at 0.15 and up.
    /// So a quiet sound is the taps, or part of them, alone.
    var isQuiet: Bool { peak <= 0.05 }
}

/// The sounds in `output`, oldest first.
private func sounds(in output: some Collection<Float>) -> [Sound] {
    let gap = 240
    var found: [Sound] = []
    var current: Sound?
    for (index, sample) in output.enumerated() {
        let level = abs(sample)
        guard level >= 0.001 else { continue }
        if let sound = current, index - sound.last <= gap {
            current?.last = index
            current?.frames += 1
            current?.peak = max(sound.peak, level)
        } else {
            if let sound = current {
                found.append(sound)
            }
            current = Sound(first: index, last: index, frames: 1, peak: level)
        }
    }
    if let current {
        found.append(current)
    }
    return found
}

/// The taps as `sounds(in:)` finds them: one sound per tap.
private let soundOfTheTaps = sounds(in: SoundCue.agentWorking.samples(sampleRate: 48_000))

/// Where the taps came out whole in `output`, with nothing else sounding over them: the first
/// sample of each run of quiet sounds, one per tap, together as much sound as the taps make.
private func tapsAlone(in output: [Float]) -> [Int] {
    let all = sounds(in: output)
    let taps = soundOfTheTaps.count
    let tapFrames = soundOfTheTaps.reduce(0) { $0 + $1.frames }
    guard all.count >= taps else { return [] }
    return (0...(all.count - taps)).compactMap { index in
        let run = all[index..<(index + taps)]
        let frames = run.reduce(0) { $0 + $1.frames }
        guard run.allSatisfy(\.isQuiet), abs(frames - tapFrames) <= tapFrames / 20 else { return nil }
        return run.first?.first
    }
}

/// How much sound the loud sounds in `output` make together, and the loudest of them: what a
/// reply said in `FakeKokoro`'s tone sounds like.
private func loudness(of output: some Collection<Float>) -> (frames: Int, peak: Float) {
    let loud = sounds(in: output).filter { !$0.isQuiet }
    return (loud.reduce(0) { $0 + $1.frames }, loud.map(\.peak).max() ?? 0)
}

/// Where the last loud sound in `output` ends, before `index`. Nil if there is none.
private func endOfLastLoudSound(in output: [Float], before index: Int) -> Int? {
    sounds(in: output[..<index]).last { !$0.isQuiet }?.last
}

/// How loud `text` is said on its own by `loop` now, as `loudness(of:)` measures it. Waits until
/// it has been said, and a moment after.
@MainActor
private func loudnessAlone(of text: String, by loop: VoiceLoop, on bed: VoiceTestBed) async -> (frames: Int, peak: Float) {
    let start = bed.audio.output.count
    loop.speak(text)
    #expect(await eventually { loop.state == .listening(partial: "") })
    #expect(await audioGoesBy(0.5, on: bed))
    return loudness(of: bed.audio.output[start...])
}

/// Whether `output` holds a reply said as loud as `alone`, with nothing over it: as much loud
/// sound, within a hundredth, and no louder.
private func holdsReplyAlone(_ output: [Float], saidAlone alone: (frames: Int, peak: Float)) -> Bool {
    let heard = loudness(of: output)
    return abs(heard.frames - alone.frames) <= alone.frames / 100 && heard.peak <= alone.peak * 1.02
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct WorkingCueTests {
    @Test func whenTheAgentStartsWorkingTheTapsPlayOnceAndAgainOnlyWhenItStartsAgain() async throws {
        let bed = VoiceTestBed()
        let loop = try await listeningLoopWithCues(on: bed)
        defer { loop.stop() }
        #expect(await staysSilent(on: bed))

        loop.isAgentWorking = true

        #expect(loop.hasPlayedWorkingCue)
        // Seconds later, it has played once and not again.
        #expect(await playsOnce(.agentWorking, on: bed))
        #expect(loop.state == .listening(partial: ""))

        loop.isAgentWorking = false

        #expect(!loop.hasPlayedWorkingCue)
        #expect(await staysSilent(on: bed))

        loop.isAgentWorking = true

        #expect(await playsOnce(.agentWorking, on: bed))
    }

    @Test func nothingPlaysWhileTheLoopIsOffAndTheTapsFollowTheStartCue() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop(soundCues: true)

        loop.isAgentWorking = true
        try await settle()

        #expect(!loop.hasPlayedWorkingCue)
        #expect(bed.audio.engines.isEmpty)
        #expect(bed.audio.playedFrames == 0)

        try await loop.start()
        defer { loop.stop() }

        #expect(loop.hasPlayedWorkingCue)
        #expect(await audioGoesBy(on: bed))
        let expected = soundingFrames(of: .listeningStarted) + soundingFrames(of: .agentWorking)
        #expect(abs(bed.audio.playedFrames - expected) <= expected / 10)
    }

    @Test func theTapsWaitForTheReplyBeingSaidAndDoNotFollowLaterReplies() async throws {
        let bed = VoiceTestBed()
        let loop = try await listeningLoopWithCues(on: bed)
        defer { loop.stop() }
        // How much sound the reply makes alone, for comparison.
        let beforeAlone = bed.audio.playedFrames
        loop.speak("Done.")
        #expect(await eventually { loop.state == .listening(partial: "") })
        #expect(await lastPassPlays(on: bed))
        #expect(await staysSilent(on: bed))
        let reply = bed.audio.playedFrames - beforeAlone
        let taps = soundingFrames(of: .agentWorking)

        let beforeWorking = bed.audio.playedFrames
        loop.speak("Done.")
        loop.isAgentWorking = true

        #expect(!loop.hasPlayedWorkingCue)
        #expect(await eventually { loop.state == .listening(partial: "") })
        #expect(loop.hasPlayedWorkingCue)
        #expect(await audioGoesBy(on: bed))
        #expect(abs(bed.audio.playedFrames - beforeWorking - reply - taps) <= taps / 4)

        // Still working, as on a reply that comes in parts: no taps after the next one.
        let beforeNext = bed.audio.playedFrames
        loop.speak("Done.")
        #expect(await eventually { loop.state == .listening(partial: "") })
        #expect(await audioGoesBy(on: bed))
        #expect(abs(bed.audio.playedFrames - beforeNext - reply) <= taps / 4)
    }

    @Test func aReplyCutOffLetsTheTapsPlayAtOnce() async throws {
        let bed = VoiceTestBed()
        let loop = try await listeningLoopWithCues(on: bed)
        defer { loop.stop() }
        loop.speak(longReply)
        loop.isAgentWorking = true
        #expect(!loop.hasPlayedWorkingCue)

        loop.stopSpeaking()

        #expect(loop.state == .listening(partial: ""))
        #expect(loop.hasPlayedWorkingCue)
        let played = bed.audio.playedFrames
        #expect(await eventually { bed.audio.playedFrames > played })
    }

    @Test func withoutEchoCancellationTheyNeverPlay() async throws {
        let bed = VoiceTestBed()
        bed.hasVoiceProcessing = false
        let loop = try await listeningLoopWithCues(on: bed)
        defer { loop.stop() }

        loop.isAgentWorking = true

        // The microphone would hear them as loud as they play.
        #expect(!loop.hasPlayedWorkingCue)
        #expect(await staysSilent(on: bed))
        #expect(loop.state == .listening(partial: ""))
    }

    @Test func withTheSoundCuesOffTheyNeverPlay() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        loop.isAgentWorking = true

        #expect(!loop.hasPlayedWorkingCue)
        #expect(await staysSilent(on: bed))
    }

    @Test func tapsCutOffWhenTheEngineStopsByItselfPlayAgainInFullOnce() async throws {
        let bed = VoiceTestBed()
        let loop = try await listeningLoopWithCues(on: bed)
        defer { loop.stop() }
        let engine = try #require(bed.audio.engines.last)
        loop.isAgentWorking = true

        // As on the iPhone, the engine stops by itself before the taps have played: at once, and
        // the engine renders on the main actor, so none of them have.
        engine.stop()
        let played = bed.audio.playedFrames
        postConfigurationChange(for: engine)

        #expect(await eventually { engine.isRunning })
        // Played again as a cut-off cue is, and not a second time for still working.
        #expect(await audioGoesBy(on: bed))
        let taps = soundingFrames(of: .agentWorking)
        #expect(abs(bed.audio.playedFrames - played - taps) <= taps / 10)
        #expect(loop.hasPlayedWorkingCue)
    }

    @Test func theyDoNotPlayAgainWhenTheEngineRestartsOrIsRebuilt() async throws {
        let bed = VoiceTestBed()
        let loop = try await listeningLoopWithCues(on: bed)
        defer { loop.stop() }
        let first = try #require(bed.audio.engines.last)
        loop.isAgentWorking = true
        #expect(await playsOnce(.agentWorking, on: bed))

        // The audio hardware changed: the engine stops itself, and is started again.
        first.stop()
        postConfigurationChange(for: first)

        #expect(await eventually { first.isRunning })
        #expect(await staysSilent(on: bed))
        #expect(bed.audio.engines.count == 1)

        // A settings change builds a new engine, which plays only its start cue.
        let played = bed.audio.playedFrames
        loop.pausesOtherAudio = false

        #expect(!first.isRunning)
        #expect(await eventually { bed.audio.engines.count == 2 && bed.recognizer.isStarted })
        #expect(await audioGoesBy(on: bed))
        let startCue = soundingFrames(of: .listeningStarted)
        #expect(abs(bed.audio.playedFrames - played - startCue) <= startCue / 10)
        #expect(loop.hasPlayedWorkingCue)
    }

    @Test func tapsAskedForDuringAReplyPlayOnlyOnceItsSoundHasEnded() async throws {
        let bed = VoiceTestBed()
        let loop = try await recordingKokoroLoopWithCues(on: bed)
        defer { loop.stop() }
        let alone = await loudnessAlone(of: "Done.", by: loop, on: bed)
        let start = bed.audio.output.count

        loop.speak("Done.")
        loop.isAgentWorking = true

        #expect(!loop.hasPlayedWorkingCue)
        #expect(await eventually { loop.state == .listening(partial: "") })
        #expect(await audioGoesBy(on: bed))
        // Each whole, with nothing sounding over it, the taps after the reply's last sound.
        let output = Array(bed.audio.output[start...])
        #expect(holdsReplyAlone(output, saidAlone: alone))
        let taps = tapsAlone(in: output)
        #expect(taps.count == 1)
        #expect(taps.first.flatMap { endOfLastLoudSound(in: output, before: $0) } != nil)
    }

    @Test(arguments: [Float(1), 2])
    func tapsAfterAReplyIsCutOffDoNotSoundOverItsLastSound(pitch: Float) async throws {
        let bed = VoiceTestBed()
        let loop = try await recordingKokoroLoopWithCues(on: bed)
        defer { loop.stop() }
        // A shifted reply runs on after its player stops, as the pitch shift empties.
        loop.speechPitch = pitch
        let start = bed.audio.output.count
        let before = bed.audio.playedFrames
        loop.speak("One. Two. Three. Four.")
        loop.isAgentWorking = true
        #expect(await eventually { bed.audio.playedFrames > before })

        loop.stopSpeaking()

        #expect(loop.state == .listening(partial: ""))
        #expect(await audioGoesBy(on: bed))
        // Whole and alone, after the cut-off reply's last sound.
        let output = Array(bed.audio.output[start...])
        let taps = tapsAlone(in: output)
        #expect(taps.count == 1)
        #expect(taps.first.flatMap { endOfLastLoudSound(in: output, before: $0) } != nil)
    }

    @Test func aReplyThatStartsWhileTheTapsPlayCutsThemOffAndTheyPlayAfterIt() async throws {
        let bed = VoiceTestBed()
        let loop = try await recordingKokoroLoopWithCues(on: bed)
        defer { loop.stop() }
        let alone = await loudnessAlone(of: "One. Two. Three.", by: loop, on: bed)
        let start = bed.audio.output.count

        loop.isAgentWorking = true
        #expect(loop.hasPlayedWorkingCue)
        loop.speak("One. Two. Three.")

        #expect(loop.state == .speaking)
        #expect(!loop.hasPlayedWorkingCue)
        #expect(await eventually { loop.state == .listening(partial: "") })
        #expect(await audioGoesBy(on: bed))
        // The reply with nothing over it, then, the agent still working, the taps again in full.
        let output = Array(bed.audio.output[start...])
        #expect(holdsReplyAlone(output, saidAlone: alone))
        let taps = tapsAlone(in: output)
        #expect(taps.count == 1)
        #expect(taps.first.flatMap { endOfLastLoudSound(in: output, before: $0) } != nil)
        #expect(loop.hasPlayedWorkingCue)
    }

    @Test func aReplyThatStartsPartWayThroughTheTapsCutsOffTheRest() async throws {
        let bed = VoiceTestBed()
        let loop = try await recordingKokoroLoopWithCues(on: bed)
        defer { loop.stop() }
        let alone = await loudnessAlone(of: "One. Two. Three.", by: loop, on: bed)
        let start = bed.audio.output.count

        loop.isAgentWorking = true
        // Two render passes, with no await before the reply: the lead-in and most of the first
        // tap play, and the rest is still to come when the reply starts.
        bed.audio.render(passes: 2)
        let partial = sounds(in: bed.audio.output[start...])
        #expect(!partial.isEmpty && partial.allSatisfy(\.isQuiet))
        #expect(tapsAlone(in: Array(bed.audio.output[start...])).isEmpty)
        loop.speak("One. Two. Three.")

        #expect(await eventually { loop.state == .listening(partial: "") })
        #expect(await audioGoesBy(on: bed))
        // Nothing of the taps sounds with the reply, and they play in full after it.
        let output = Array(bed.audio.output[start...])
        #expect(holdsReplyAlone(output, saidAlone: alone))
        let replyStart = try #require(sounds(in: output).first { !$0.isQuiet }?.first)
        let replyEnd = try #require(endOfLastLoudSound(in: output, before: output.count))
        #expect(!sounds(in: output).contains { $0.isQuiet && $0.last >= replyStart && $0.first <= replyEnd })
        #expect(tapsAlone(in: Array(output[replyEnd...])).count == 1)
    }

    @Test func tapsWaitingBehindAnotherCueDoNotPlayWithAReplyThatStarts() async throws {
        let bed = VoiceTestBed()
        let loop = try await recordingKokoroLoopWithCues(on: bed)
        defer { loop.stop() }
        let start = bed.audio.output.count

        // The taps would start once the chime has played, with the reply well under way.
        loop.play(.reaction)
        loop.isAgentWorking = true
        loop.speak("One. Two. Three. Four.")

        #expect(await eventually { loop.state == .listening(partial: "") })
        #expect(await audioGoesBy(on: bed))
        // The chime plays with the reply, as cues do, but the taps wait until it has ended.
        let output = Array(bed.audio.output[start...])
        let taps = tapsAlone(in: output)
        #expect(taps.count == 1)
        let replyEnd = taps.first.flatMap { endOfLastLoudSound(in: output, before: $0) }
        let replyLength = Int(4 * FakeKokoro.secondsPerSentence * 48_000)
        #expect((replyEnd ?? 0) >= replyLength)
    }

    @Test func tapsCutOffWhenTheEngineStopsByItselfWaitForTheReplyItStartsAgain() async throws {
        let bed = VoiceTestBed()
        let loop = try await recordingKokoroLoopWithCues(on: bed)
        defer { loop.stop() }
        let engine = try #require(bed.audio.engines.last)
        let start = bed.audio.output.count
        loop.isAgentWorking = true

        // The engine stops by itself before the taps have played, and a reply arrives before the
        // loop hears of it: it waits for the engine.
        engine.stop()
        loop.speak("One. Two. Three.")
        postConfigurationChange(for: engine)

        #expect(await eventually { engine.isRunning })
        #expect(await eventually { bed.kokoro.requests.count == 3 })
        #expect(await eventually { loop.state == .listening(partial: "") })
        #expect(await audioGoesBy(on: bed))
        let output = Array(bed.audio.output[start...])
        // The same reply said alone afterwards, for comparison.
        let alone = await loudnessAlone(of: "One. Two. Three.", by: loop, on: bed)
        #expect(holdsReplyAlone(output, saidAlone: alone))
        let taps = tapsAlone(in: output)
        #expect(taps.count == 1)
        #expect(taps.first.flatMap { endOfLastLoudSound(in: output, before: $0) } != nil)
    }

    @Test func stoppingCutsTheTapsOffAndTheStopCuePlaysAlone() async throws {
        let bed = VoiceTestBed()
        let loop = try await listeningLoopWithCues(on: bed)
        let engine = try #require(bed.audio.engines.last)
        let played = bed.audio.playedFrames
        loop.isAgentWorking = true
        #expect(loop.hasPlayedWorkingCue)

        // At once: the engine renders on the main actor, so none of the taps have played yet.
        let stopped = ContinuousClock.now
        loop.stop()

        #expect(loop.state == .off)
        #expect(engine.isRunning)
        // The stop cue (170 ms, two passes) renders now, before an await lets the engine's
        // teardown timer run: however slow the machine, the cue has played before the engine stops.
        bed.audio.render(passes: 4)
        #expect(await eventually { !engine.isRunning })
        #expect(keptRunningThroughTheStopCue(engine, since: stopped))
        let stopCue = soundingFrames(of: .listeningStopped)
        #expect(abs(bed.audio.playedFrames - played - stopCue) <= stopCue / 10)
    }
}

// MARK: - Push-to-talk

// The pretend microphone talks (`isVoicePresent`) for whole tests here: push-to-talk decides
// what the analyzer hears of it. `ScriptedRecognizer.soundHeard` is where it was loud on the
// analyzer's timeline, so words scripted over it were said during a hold.

/// A loop in push-to-talk, started, with a pause threshold short enough that any utterance
/// sent at a pause would be sent at once, and with over a second of audio fed, so audio from
/// the start of the timeline is older than any press.
@MainActor
private func pushToTalkLoop(on bed: VoiceTestBed, soundCues: Bool = false) async throws -> VoiceLoop {
    let loop = bed.makeLoop(soundCues: soundCues)
    loop.pauseThreshold = .milliseconds(50)
    loop.isPushToTalk = true
    try await loop.start()
    #expect(await eventually { bed.recognizer.heardFrames > 16_000 })
    return loop
}

/// Presses the button with the pretend microphone talking, and waits until the analyzer has been
/// fed some of it. Returns where it was loud, for words said during the hold.
@MainActor
private func press(_ loop: VoiceLoop, talkingOn bed: VoiceTestBed) async throws -> ClosedRange<Double> {
    bed.audio.isVoicePresent = true
    loop.beginTalking()
    #expect(loop.isTalking)
    #expect(await eventually { bed.recognizer.soundHeard != nil })
    return try #require(bed.recognizer.soundHeard)
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PushToTalkTests {
    @Test func aPressBeforeTheLoopIsListeningDoesNothing() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        loop.isPushToTalk = true
        #expect(!loop.canTalk)
        loop.beginTalking()
        #expect(!loop.isTalking)
        // A view showing whether it can talk is told when that changes.
        let changed = ChangeFlag()
        withObservationTracking {
            _ = loop.canTalk
        } onChange: {
            MainActor.assumeIsolated { changed.isSet = true }
        }
        var couldTalkWhileStarting = true
        var talkedWhileStarting = true
        bed.whenRecognizerStarts = {
            loop.beginTalking()
            couldTalkWhileStarting = loop.canTalk
            talkedWhileStarting = loop.isTalking
        }

        try await loop.start()
        defer { loop.stop() }

        #expect(!couldTalkWhileStarting)
        #expect(!talkedWhileStarting)
        #expect(!loop.isTalking)
        #expect(loop.canTalk)
        #expect(changed.isSet)
        // Without push-to-talk there is nothing to hold.
        loop.isPushToTalk = false
        #expect(!loop.canTalk)
    }

    @Test func whatIsHeardWithoutAHoldIsNotSent() async throws {
        let bed = VoiceTestBed()
        let loop = try await pushToTalkLoop(on: bed)
        defer { loop.stop() }
        let sent = UtteranceLog(loop)

        bed.recognizer.hear("Hello.", over: later, isFinal: true)
        try await settle()

        #expect(sent.texts.isEmpty)
        #expect(loop.state == .listening(partial: ""))
        #expect(!loop.isTalking)
    }

    @Test(arguments: [true, false])
    func theAnalyzerIsFedSilenceExceptDuringAHold(echoCancellation: Bool) async throws {
        let bed = VoiceTestBed()
        bed.hasVoiceProcessing = echoCancellation
        bed.audio.isVoicePresent = true
        let loop = try await pushToTalkLoop(on: bed)
        defer { loop.stop() }

        // The microphone talks, but the analyzer's timeline runs on in silence.
        let fed = bed.recognizer.heardFrames
        #expect(await eventually { bed.recognizer.heardFrames > fed + 32_000 })
        #expect(bed.recognizer.soundHeard == nil)

        let held = try await press(loop, talkingOn: bed)
        loop.endTalking()
        #expect(!loop.isTalking)

        // Once the tap is past the release, nothing loud is fed again.
        let released = bed.recognizer.heardFrames
        #expect(await eventually { bed.recognizer.heardFrames > released + 16_000 })
        let heardByThen = try #require(bed.recognizer.soundHeard)
        #expect(heardByThen.lowerBound == held.lowerBound)
        #expect(heardByThen.upperBound >= held.upperBound)
        let later = bed.recognizer.heardFrames
        #expect(await eventually { bed.recognizer.heardFrames > later + 32_000 })
        #expect(bed.recognizer.soundHeard == heardByThen)
    }

    @Test(arguments: [true, false])
    func whatIsSaidDuringAHoldIsSentOnceAfterTheReleaseAndNotAtAPause(echoCancellation: Bool) async throws {
        let bed = VoiceTestBed()
        bed.hasVoiceProcessing = echoCancellation
        let loop = try await pushToTalkLoop(on: bed)
        defer { loop.stop() }
        let sent = UtteranceLog(loop)

        let held = try await press(loop, talkingOn: bed)
        bed.recognizer.hear("Hello", over: held)
        #expect(await eventually { loop.state == .listening(partial: "Hello") })
        bed.recognizer.hear("Hello there.", over: held, isFinal: true)
        #expect(await eventually { loop.state == .listening(partial: "Hello there.") })
        // Many times the pause threshold, with nothing more heard: still held, so not sent.
        try await settle(.milliseconds(500))
        #expect(sent.texts.isEmpty)

        loop.endTalking()

        #expect(await eventually { sent.texts == ["Hello there."] })
        #expect(loop.state == .listening(partial: ""))
        // Sent once the recognizer finalized the audio through the release, after the words.
        #expect(bed.recognizer.finalizations.count == 1)
        #expect(try #require(bed.recognizer.finalizations.first) > held.upperBound)
        try await settle()
        #expect(sent.texts == ["Hello there."])
    }

    @Test func heldWordsTheRecognizerReportsSecondsAfterTheReleaseAreSent() async throws {
        let bed = VoiceTestBed()
        let loop = try await pushToTalkLoop(on: bed)
        defer { loop.stop() }
        let sent = UtteranceLog(loop)
        let held = try await press(loop, talkingOn: bed)
        // The recognizer is slow to finalize.
        bed.recognizer.whenFinalizing = { _ in try? await Task.sleep(for: .seconds(30)) }

        loop.endTalking()
        #expect(await eventually { !bed.recognizer.finalizations.isEmpty })
        let release = try #require(bed.recognizer.finalizations.first)
        try await settle(.seconds(2))
        #expect(sent.texts.isEmpty)

        // Two seconds on, its final result for the hold, through the release, arrives.
        bed.recognizer.hear("Hello there.", over: held.lowerBound...release, isFinal: true)

        #expect(await eventually { sent.texts == ["Hello there."] })
    }

    @Test func aHoldTheRecognizerNeverFinishesIsSentAfterTheTimeoutWithWhatWasHeard() async throws {
        let bed = VoiceTestBed()
        let loop = try await pushToTalkLoop(on: bed)
        defer { loop.stop() }
        let sent = UtteranceLog(loop)
        let held = try await press(loop, talkingOn: bed)
        bed.recognizer.whenFinalizing = { _ in try? await Task.sleep(for: .seconds(30)) }
        bed.recognizer.hear("Hello there", over: held)
        #expect(await eventually { loop.state == .listening(partial: "Hello there") })

        loop.endTalking()
        try await settle(.seconds(2))
        #expect(sent.texts.isEmpty)

        #expect(await eventually { sent.texts == ["Hello there"] })
    }

    @Test func wordsTimedBeforeThePressOrAfterTheReleaseAreLeftOut() async throws {
        let bed = VoiceTestBed()
        let loop = try await pushToTalkLoop(on: bed)
        defer { loop.stop() }
        let sent = UtteranceLog(loop)
        let held = try await press(loop, talkingOn: bed)

        // A late result for audio from long before the press.
        bed.recognizer.hear("Earlier.", over: 0...0.5, isFinal: true)
        bed.recognizer.hear("Hello there.", over: held, isFinal: true)
        #expect(await eventually { loop.state == .listening(partial: "Hello there.") })
        // As it finalizes, the recognizer reports a word from the silence after the release.
        let recognizer = bed.recognizer
        recognizer.whenFinalizing = { release in
            recognizer.hear("Mhm.", over: (release.seconds + 0.1)...(release.seconds + 0.5), isFinal: true)
        }
        loop.endTalking()

        #expect(await eventually { sent.texts == ["Hello there."] })
        try await settle()
        #expect(sent.texts == ["Hello there."])
    }

    @Test func aReleaseWithNothingHeardSendsNothing() async throws {
        let bed = VoiceTestBed()
        let loop = try await pushToTalkLoop(on: bed)
        defer { loop.stop() }
        let sent = UtteranceLog(loop)

        loop.beginTalking()
        loop.endTalking()

        #expect(await eventually { bed.recognizer.finalizations.count == 1 })
        try await settle()
        #expect(sent.texts.isEmpty)
        #expect(loop.state == .listening(partial: ""))
        // Once the release is over, a reply plays.
        loop.speak("Hi.")
        #expect(await eventually { loop.state == .speaking })
        #expect(sent.texts.isEmpty)
    }

    @Test func aFinalResultReadOnlyAfterFinalizingReturnedIsStillSent() async throws {
        let bed = VoiceTestBed()
        let loop = try await pushToTalkLoop(on: bed)
        defer { loop.stop() }
        let sent = UtteranceLog(loop)
        let held = try await press(loop, talkingOn: bed)
        bed.recognizer.hear("Hello", over: held)
        #expect(await eventually { loop.state == .listening(partial: "Hello") })
        // Finalizing publishes its final result, but the loop reads it only after it returned.
        bed.recognizer.reportsFinalOnFinalizing = false

        loop.endTalking()
        #expect(await eventually { bed.recognizer.finalizationsFinished == 1 })
        let release = try #require(bed.recognizer.finalizations.first)
        // Longer than a pause check: the volatile word isn't final yet, so it waits.
        try await settle(.milliseconds(200))
        #expect(sent.texts.isEmpty)
        bed.recognizer.hear("Hello there.", over: held.lowerBound...release, isFinal: true)

        #expect(await eventually { sent.texts == ["Hello there."] })
    }

    /// Presses, says "Hello there." and releases, with the recognizer slow to finalize, so the
    /// release is still waiting for it.
    private func releaseWaitingForTheRecognizer(_ loop: VoiceLoop, on bed: VoiceTestBed) async throws {
        let held = try await press(loop, talkingOn: bed)
        bed.recognizer.hear("Hello there.", over: held, isFinal: true)
        #expect(await eventually { loop.state == .listening(partial: "Hello there.") })
        bed.recognizer.whenFinalizing = { _ in try? await Task.sleep(for: .seconds(30)) }
        loop.endTalking()
        #expect(await eventually { bed.recognizer.finalizations.count == 1 })
    }

    @Test func aReleasedHoldIsSentWithWhatWasHeardWhenTheEngineIsRebuiltMeanwhile() async throws {
        let bed = VoiceTestBed()
        let loop = try await pushToTalkLoop(on: bed)
        defer { loop.stop() }
        let sent = UtteranceLog(loop)
        try await releaseWaitingForTheRecognizer(loop, on: bed)
        #expect(sent.texts.isEmpty)

        // A settings change rebuilds the engine, as AirPods connecting can.
        loop.pausesOtherAudio = false

        #expect(await eventually { sent.texts == ["Hello there."] })
        #expect(await eventually { bed.recognizers.count == 2 && bed.recognizer.isStarted })
        #expect(loop.state == .listening(partial: ""))
    }

    @Test func aReleasedHoldIsSentWithWhatWasHeardWhenVoiceModeStopsMeanwhile() async throws {
        let bed = VoiceTestBed()
        let loop = try await pushToTalkLoop(on: bed)
        let sent = UtteranceLog(loop)
        try await releaseWaitingForTheRecognizer(loop, on: bed)
        #expect(sent.texts.isEmpty)

        // Adam lets go and closes the sheet at once.
        loop.stop()

        #expect(await eventually { sent.texts == ["Hello there."] })
        #expect(loop.state == .off)
    }

    @Test func aHoldStillHeldWhenTheEngineIsRebuiltIsDroppedButCarriesOn() async throws {
        let bed = VoiceTestBed()
        let loop = try await pushToTalkLoop(on: bed)
        defer { loop.stop() }
        let sent = UtteranceLog(loop)
        let held = try await press(loop, talkingOn: bed)
        bed.recognizer.hear("Never mind.", over: held, isFinal: true)
        #expect(await eventually { loop.state == .listening(partial: "Never mind.") })

        loop.pausesOtherAudio = false

        // What it heard goes with the old engine, as an utterance in progress does hands-free.
        #expect(await eventually { bed.recognizers.count == 2 && bed.recognizer.isStarted })
        #expect(loop.isTalking)
        #expect(loop.state == .listening(partial: ""))
        try await settle()
        #expect(sent.texts.isEmpty)
        // The hold carries on into the new engine.
        #expect(await eventually { bed.recognizer.soundHeard != nil })
        let heard = try #require(bed.recognizer.soundHeard)
        bed.recognizer.hear("Hello.", over: heard, isFinal: true)
        #expect(await eventually { loop.state == .listening(partial: "Hello.") })
        loop.endTalking()
        #expect(await eventually { sent.texts == ["Hello."] })
    }

    @Test func aPressStopsTheReplyAndOneArrivingDuringTheHoldWaitsForTheRelease() async throws {
        let bed = VoiceTestBed()
        let loop = try await pushToTalkLoop(on: bed)
        defer { loop.stop() }
        loop.speak(longReply)
        loop.speak("Two.")
        #expect(await eventually { bed.audio.playedFrames > 0 })

        loop.beginTalking()

        #expect(loop.state == .listening(partial: ""))
        #expect(await cutOffSpeechDiesAway(on: bed))
        let playedWhenPressed = bed.audio.playedFrames
        loop.speak("Hi.")
        // Nothing plays during the hold, through many passes.
        try await settle()
        #expect(await renderPassesGoBy(20, on: bed))
        #expect(loop.state == .listening(partial: ""))
        #expect(bed.audio.playedFrames == playedWhenPressed)

        loop.endTalking()

        // Nothing was heard, so once the release is over the reply plays, and only it: the
        // queued one was dropped.
        #expect(await eventually { loop.state == .speaking })
        #expect(await eventually { loop.state == .listening(partial: "") })
        #expect(bed.audio.playedFrames > playedWhenPressed)
        try await settle()
        #expect(loop.state == .listening(partial: ""))
    }

    @Test func aSecondPressBeforeTheFirstIsSentKeepsBothHoldsAsOneUtterance() async throws {
        let bed = VoiceTestBed()
        let loop = try await pushToTalkLoop(on: bed)
        defer { loop.stop() }
        let sent = UtteranceLog(loop)
        let first = try await press(loop, talkingOn: bed)
        bed.recognizer.whenFinalizing = { _ in try? await Task.sleep(for: .seconds(30)) }
        loop.endTalking()
        #expect(await eventually { bed.recognizer.finalizations.count == 1 })
        let firstRelease = try #require(bed.recognizer.finalizations.first)
        bed.recognizer.whenFinalizing = nil

        loop.beginTalking()
        // The first hold's words, reported late, still count.
        bed.recognizer.hear("Hello", over: first, isFinal: true)
        #expect(await eventually { (bed.recognizer.soundHeard?.upperBound ?? 0) > firstRelease + 0.5 })
        let second = try #require(bed.recognizer.soundHeard).upperBound
        bed.recognizer.hear("there.", over: (firstRelease + 0.001)...second, isFinal: true)
        #expect(await eventually { loop.state == .listening(partial: "Hello there.") })
        #expect(sent.texts.isEmpty)
        loop.endTalking()

        #expect(await eventually { sent.texts == ["Hello there."] })
        try await settle()
        #expect(sent.texts == ["Hello there."])
    }

    @Test func turningPushToTalkOffListensHandsFreeAgain() async throws {
        let bed = VoiceTestBed()
        let loop = try await pushToTalkLoop(on: bed)
        defer { loop.stop() }
        let sent = UtteranceLog(loop)
        let held = try await press(loop, talkingOn: bed)
        bed.recognizer.hear("Hello.", over: held, isFinal: true)
        #expect(await eventually { loop.state == .listening(partial: "Hello.") })
        bed.audio.isVoicePresent = false

        loop.isPushToTalk = false

        // The hold ends, and what it heard is sent at a pause, as hands-free.
        #expect(!loop.isTalking)
        #expect(await eventually { sent.texts == ["Hello."] })
        // Without a press, the microphone is heard, and what it says is sent.
        bed.audio.isVoicePresent = true
        let heard = try #require(bed.recognizer.soundHeard)
        #expect(await eventually { (bed.recognizer.soundHeard?.upperBound ?? 0) > heard.upperBound + 1 })
        bed.audio.isVoicePresent = false
        bed.recognizer.hear("Again.", over: later, isFinal: true)
        #expect(await eventually { sent.texts == ["Hello.", "Again."] })
        // And a press does nothing.
        loop.beginTalking()
        #expect(!loop.isTalking)
    }

    @Test func aPressAndAReleaseEachPlayTheirCueAndOpeningOrClosingPlaysNone() async throws {
        let bed = VoiceTestBed()
        let loop = try await pushToTalkLoop(on: bed, soundCues: true)
        // Starting isn't a press: Adam can't talk yet. A start cue, had it played, would have by now.
        #expect(await cuesPlayOut(on: bed))
        #expect(bed.audio.playedFrames == 0)

        loop.beginTalking()
        #expect(await eventually { bed.audio.playedFrames > 0 })
        #expect(await cuesPlayOut(on: bed))
        let pressCue = bed.audio.playedFrames
        loop.endTalking()
        #expect(await eventually { bed.audio.playedFrames > pressCue })
        #expect(await cuesPlayOut(on: bed))
        let releaseCue = bed.audio.playedFrames - pressCue

        // The same taps, in the other order.
        #expect(abs(releaseCue - pressCue) <= pressCue / 10)
        loop.stop()
        try await settle()
        #expect(bed.audio.playedFrames == pressCue + releaseCue)
    }

    @Test func withoutEchoCancellationTheMicrophoneOpensOnceTheStartCueHasPlayed() async throws {
        let bed = VoiceTestBed()
        bed.hasVoiceProcessing = false
        let loop = try await pushToTalkLoop(on: bed, soundCues: true)
        defer { loop.stop() }
        bed.audio.isVoicePresent = true

        loop.beginTalking()

        // The microphone would hear the cue as loud as it plays, so it stays muted meanwhile.
        try await settle(.milliseconds(200))
        #expect(bed.recognizer.soundHeard == nil)
        #expect(await eventually { bed.recognizer.soundHeard != nil })
    }
}

// MARK: - Voices

@Suite struct VoiceOptionTests {
    @MainActor
    @Test func availableSystemVoicesAreForTheCurrentLanguageBestQualityFirst() throws {
        let all = VoiceLoop.availableVoices()
        let voices = all.filter { $0.engine == .system }
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let systemDefault = AVSpeechSynthesisVoice(language: language)?.identifier

        #expect(!voices.isEmpty)
        #expect(Set(all.map(\.id)).count == all.count)
        // The system voices come first, then any Kokoro voices.
        #expect(Array(all.prefix(voices.count)) == voices)
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
        #expect(option.engine == .system)
    }
}
