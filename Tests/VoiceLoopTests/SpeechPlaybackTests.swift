@preconcurrency import AVFoundation
import Synchronization
import Testing
@testable import VoiceLoop
import VoiceLoopTestSupport

// `SpeechPlayback` and `SynthesisObserver` on their own, fed the way AVSpeechSynthesizer feeds
// them, with the player of a real `Pipeline` on the offline test bed. Also the pitch shift
// between that player and the speaker.

/// A started pipeline whose player is playing, as the voice loop has while it speaks.
@MainActor
private func makePlayingPipeline(on bed: VoiceTestBed) throws -> Pipeline {
    let pipeline = try Pipeline(
        analyzerFormat: ScriptedRecognizer().audioFormat,
        voiceProcessing: false,
        ducksOtherAudio: true,
        session: 0,
        environment: bed.environment
    )
    try pipeline.engine.start()
    pipeline.speech.player.play()
    return pipeline
}

/// A buffer like the synthesizer's: 22.05 kHz mono, holding a tone.
private func speechBuffer(seconds: Double) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
    let frames = AVAudioFrameCount(seconds * format.sampleRate)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try #require(buffer.floatChannelData?[0])
    for frame in 0..<Int(frames) {
        samples[frame] = 0.5 * sinf(2 * .pi * 440 * Float(frame) / Float(format.sampleRate))
    }
    return buffer
}

/// How many 48 kHz frames the speaker plays for `seconds` of speech.
private func speakerFrames(forSeconds seconds: Double) -> Int {
    Int(seconds * 48_000)
}

/// Lets the last render pass reach the speaker. Offline, a playback finishes once the player has
/// rendered its last buffer, and the pitch shift after the player pulls it a pass ahead of the
/// output (see `SpeechOutput.completion`).
private func letTheLastPassPlay() async throws {
    try await Task.sleep(for: .milliseconds(50))
}

/// Counts the calls to a playback's `onFinished`, which arrive on an audio thread.
private final class FinishCounter: Sendable {
    private let calls = Mutex(0)
    var count: Int { calls.withLock { $0 } }
    func increment() { calls.withLock { $0 += 1 } }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SpeechPlaybackTests {
    private func makePlayback(on pipeline: Pipeline, finished: FinishCounter) -> SpeechPlayback {
        pipeline.speech.makePlayback(text: "Hello.") { _ in
            finished.increment()
        }
    }

    @Test func everyBufferIsPlayedAndTheMessageFinishesOnceAfterTheLast() async throws {
        let bed = VoiceTestBed()
        let pipeline = try makePlayingPipeline(on: bed)
        defer { pipeline.tearDown() }
        let finished = FinishCounter()
        let playback = makePlayback(on: pipeline, finished: finished)

        for _ in 0..<3 {
            playback.receive(try speechBuffer(seconds: 0.1))
        }
        // The last buffer is held back until the synthesizer says there are no more.
        try await Task.sleep(for: .milliseconds(100))
        #expect(finished.count == 0)
        playback.synthesisFinished()

        #expect(await eventually { finished.count == 1 })
        try await letTheLastPassPlay()
        let expected = speakerFrames(forSeconds: 0.3)
        #expect(abs(bed.audio.playedFrames - expected) <= expected / 20)
    }

    @Test func aBufferThatArrivesAfterSynthesisFinishedIsStillPlayed() async throws {
        let bed = VoiceTestBed()
        let pipeline = try makePlayingPipeline(on: bed)
        defer { pipeline.tearDown() }
        let finished = FinishCounter()
        let playback = makePlayback(on: pipeline, finished: finished)

        playback.receive(try speechBuffer(seconds: 0.1))
        playback.synthesisFinished()
        playback.receive(try speechBuffer(seconds: 0.1))

        // Each of the two ends the message as far as the playback knows; the loop ignores
        // the second report.
        #expect(await eventually { finished.count == 2 })
        try await letTheLastPassPlay()
        let expected = speakerFrames(forSeconds: 0.2)
        #expect(abs(bed.audio.playedFrames - expected) <= expected / 20)
    }

    @Test func aMessageWithNoSoundFinishesAsSoonAsSynthesisDoes() async throws {
        let bed = VoiceTestBed()
        let pipeline = try makePlayingPipeline(on: bed)
        defer { pipeline.tearDown() }
        let finished = FinishCounter()
        let playback = makePlayback(on: pipeline, finished: finished)

        // The synthesizer sometimes ends with an empty buffer; it carries nothing to play.
        let empty = try speechBuffer(seconds: 0.1)
        empty.frameLength = 0
        playback.receive(empty)
        playback.synthesisFinished()

        #expect(finished.count == 1)
        // Reported once, even if the synthesizer's delegate fires again.
        playback.synthesisFinished()
        #expect(finished.count == 1)
        #expect(bed.audio.playedFrames == 0)
    }

    @Test func aCancelledPlaybackPlaysNothingMoreAndNeverFinishes() async throws {
        let bed = VoiceTestBed()
        let pipeline = try makePlayingPipeline(on: bed)
        defer { pipeline.tearDown() }
        let finished = FinishCounter()
        let playback = makePlayback(on: pipeline, finished: finished)

        playback.receive(try speechBuffer(seconds: 0.1))
        playback.cancel()
        // The synthesizer keeps writing a cancelled utterance to its end.
        playback.receive(try speechBuffer(seconds: 0.1))
        playback.synthesisFinished()
        try await Task.sleep(for: .milliseconds(250))

        #expect(finished.count == 0)
        #expect(bed.audio.playedFrames == 0)
    }

    @Test func theFirstBufferIsTimedWhenItIsScheduledNotWhenItArrives() async throws {
        let bed = VoiceTestBed()
        let pipeline = try makePlayingPipeline(on: bed)
        defer { pipeline.tearDown() }
        let playback = makePlayback(on: pipeline, finished: FinishCounter())
        let before = TimelineClock.now()

        playback.receive(try speechBuffer(seconds: 0.1))
        // Held back until the next buffer arrives.
        #expect(playback.firstAudioHostTime == nil)
        playback.receive(try speechBuffer(seconds: 0.1))
        let firstAudio = try #require(playback.firstAudioHostTime)
        #expect(firstAudio >= before)

        // Later buffers don't move it.
        playback.receive(try speechBuffer(seconds: 0.1))
        playback.synthesisFinished()
        #expect(playback.firstAudioHostTime == firstAudio)
    }

    @Test func aOneBufferMessageIsTimedWhenSynthesisFinishes() async throws {
        let bed = VoiceTestBed()
        let pipeline = try makePlayingPipeline(on: bed)
        defer { pipeline.tearDown() }
        let playback = makePlayback(on: pipeline, finished: FinishCounter())

        playback.receive(try speechBuffer(seconds: 0.1))
        #expect(playback.firstAudioHostTime == nil)
        playback.synthesisFinished()

        #expect(playback.firstAudioHostTime != nil)
    }

    @Test func onlyTheTrackedUtterancesFinishReachesThePlayback() async throws {
        let bed = VoiceTestBed()
        let pipeline = try makePlayingPipeline(on: bed)
        defer { pipeline.tearDown() }
        let finished = FinishCounter()
        let playback = makePlayback(on: pipeline, finished: finished)
        let observer = SynthesisObserver()
        let synthesizer = AVSpeechSynthesizer()
        let cancelled = AVSpeechUtterance(string: "The reply that was cut off.")
        let current = AVSpeechUtterance(string: "Hello.")

        observer.track(current, playback: playback)
        // A cancelled utterance finishes synthesizing after the next one has started.
        observer.speechSynthesizer(synthesizer, didFinish: cancelled)
        #expect(finished.count == 0)

        observer.speechSynthesizer(synthesizer, didFinish: current)
        #expect(finished.count == 1)

        // Nothing is tracked any more, so a repeat is dropped.
        observer.speechSynthesizer(synthesizer, didFinish: current)
        #expect(finished.count == 1)
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PitchShiftTests {
    /// Plays a 440 Hz tone through a pipeline at `pitch` and returns how often the sound that
    /// came out of the speaker crossed zero, per second of sound.
    private func zeroCrossingsPerSecond(atPitch pitch: Float) async throws -> Double {
        let bed = VoiceTestBed()
        let pipeline = try makePlayingPipeline(on: bed)
        defer { pipeline.tearDown() }
        let finished = FinishCounter()
        pipeline.speech.setPitch(pitch)
        let playback = pipeline.speech.makePlayback(text: "Hello.") { _ in
            finished.increment()
        }

        playback.receive(try speechBuffer(seconds: 0.5))
        playback.synthesisFinished()
        #expect(await eventually { finished.count == 1 })
        try await letTheLastPassPlay()

        #expect(bed.audio.playedFrames > 0)
        return Double(bed.audio.playedZeroCrossings) / Double(bed.audio.playedFrames) * 48_000
    }

    @Test func aShiftedToneComesOutAnOctaveAwayAndAnUnshiftedOneAsItWas() async throws {
        let normal = try await zeroCrossingsPerSecond(atPitch: VoiceLoop.defaultSpeechPitch)
        let higher = try await zeroCrossingsPerSecond(atPitch: VoiceLoop.speechPitches.upperBound)
        let lower = try await zeroCrossingsPerSecond(atPitch: VoiceLoop.speechPitches.lowerBound)

        // A 440 Hz tone crosses zero 880 times a second: 1760 an octave up, 440 an octave down.
        #expect(abs(normal - 880) <= 880 / 20)
        #expect(abs(higher - 1760) <= 1760 / 10)
        #expect(abs(lower - 440) <= 440 / 10)
    }
}

@Suite struct AudioConversionTests {
    @Test func convertingResamplesToTheOutputFormat() throws {
        let buffer = try speechBuffer(seconds: 0.1)
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let converter = try #require(AVAudioConverter(from: buffer.format, to: output))

        let converted = try #require(convert(buffer, with: converter))

        #expect(converted.format.sampleRate == 48_000)
        // 0.1 s of audio, give or take the resampler's filter delay.
        #expect(abs(Int(converted.frameLength) - 4800) <= 100)
    }

    @Test func convertingAnEmptyBufferGivesNothing() throws {
        let buffer = try speechBuffer(seconds: 0.1)
        buffer.frameLength = 0
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let converter = try #require(AVAudioConverter(from: buffer.format, to: output))

        #expect(convert(buffer, with: converter) == nil)
    }

    @Test func voiceQualityMapsFromTheSystemsQuality() {
        #expect(VoiceOption.Quality(.premium) == .premium)
        #expect(VoiceOption.Quality(.enhanced) == .enhanced)
        #expect(VoiceOption.Quality(.default) == .standard)
    }
}
