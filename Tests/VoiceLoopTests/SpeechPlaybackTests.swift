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
        microphoneGate: MicrophoneGate(),
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

/// Counts the calls to a playback's `onFinished`, which arrive on an audio thread.
private final class FinishCounter: Sendable {
    private let calls = Mutex(0)
    var count: Int { calls.withLock { $0 } }
    func increment() { calls.withLock { $0 += 1 } }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SpeechPlaybackTests {
    @Test func shortSpeechPlaysAtFullVolumeFromStartToEnd() throws {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let output = try SpeechOutput(engine: engine)
        output.connect()
        try engine.start()
        defer { engine.stop() }
        let playback = output.makePlayback(text: "Hi.") { _ in }

        // 75 ms, shorter than even the former fade-in at maximum speed. Multiple buffers
        // exercise both ordinary scheduling and the final buffer held until synthesis ends.
        for _ in 0..<3 {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1200))
            buffer.frameLength = 1200
            let samples = try #require(buffer.floatChannelData?[0])
            samples.update(repeating: 0.5, count: 1200)
            playback.receive(buffer)
        }
        playback.synthesisFinished()
        output.player.play()

        let rendered = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        var audible: [Float] = []
        for _ in 0..<12 {
            let status = try engine.renderOffline(1024, to: rendered)
            #expect(status == .success)
            let samples = try #require(rendered.floatChannelData?[0])
            audible += (0..<Int(rendered.frameLength)).map { samples[$0] }.filter { abs($0) > 0.0001 }
        }
        #expect(audible.count == 3600)
        #expect(audible.allSatisfy { abs($0 - 0.5) < 0.0001 })
    }

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
        // The last buffer is held back until the synthesizer says there are no more. Had all three
        // been scheduled, they (0.3 s: four passes, and one more through the pitch shift) would
        // have played by now.
        #expect(await renderPassesGoBy(10, on: bed))
        #expect(finished.count == 0)
        playback.synthesisFinished()

        #expect(await eventually { finished.count == 1 })
        #expect(await lastPassPlays(on: bed))
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

        #expect(await eventually { finished.count == 1 })
        #expect(await lastPassPlays(on: bed))
        let expected = speakerFrames(forSeconds: 0.2)
        #expect(abs(bed.audio.playedFrames - expected) <= expected / 20)
    }

    @Test func aBufferThatArrivesAfterSynthesisFinishedEndsTheMessageOnceItHasPlayed() async throws {
        // An engine rendered a pass at a time by the test, so it knows how far playback has got.
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let output = try SpeechOutput(engine: engine)
        output.connect()
        try engine.start()
        defer { engine.stop() }
        output.player.play()
        let finished = FinishCounter()
        let playback = output.makePlayback(text: "Hello.") { _ in finished.increment() }
        let rendered = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        func render(seconds: Double) throws {
            for _ in 0..<Int(seconds * 48_000 / 1024) {
                _ = try engine.renderOffline(1024, to: rendered)
            }
        }

        playback.receive(try speechBuffer(seconds: 0.1))
        playback.synthesisFinished()
        playback.receive(try speechBuffer(seconds: 0.5))

        // Well past the first buffer, with most of the late one still to play: not over yet.
        try render(seconds: 0.3)
        try await Task.sleep(for: .milliseconds(100))
        #expect(finished.count == 0)

        // Once the late one has played, it is, once.
        try render(seconds: 0.5)
        #expect(await eventually { finished.count == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(finished.count == 1)
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
        // Had either buffer been scheduled, both (0.2 s: three passes, and one more through the
        // pitch shift) would have played by now.
        #expect(await renderPassesGoBy(10, on: bed))

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
        #expect(await lastPassPlays(on: bed))

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
