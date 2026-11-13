import AVFoundation
import CoreMedia
import Testing
@testable import VoiceLoop

// The parts of the `voice.timeline` log that hold logic: its clock, the rule for where voice
// starts and ends, and what the microphone tap records. The lines themselves go to swift-log.

@Suite struct TimelineClockTests {
    @Test func countsMillisecondsFromTheStartOnTheHostClock() {
        let clock = TimelineClock(start: AVAudioTime.hostTime(forSeconds: 100))

        #expect(clock.milliseconds(at: clock.start) == 0)
        #expect(clock.milliseconds(at: clock.start + AVAudioTime.hostTime(forSeconds: 1.5)) == 1500)
        // An event from before the session started, such as a buffer captured just before.
        #expect(clock.milliseconds(at: clock.start - AVAudioTime.hostTime(forSeconds: 0.25)) == -250)
    }
}

@Suite struct VoiceSpansTests {
    /// Buffers of 1/8 s, which add up exactly.
    let buffer = 0.125

    @Test func quietBeforeAnyVoiceIsNothing() {
        var spans = VoiceSpans<Int>()
        for mark in 0..<10 {
            #expect(spans.process(isVoice: false, seconds: buffer, mark: mark) == nil)
        }
        #expect(!spans.isVoiceActive)
    }

    @Test func aSpanStartsAtTheFirstBufferCalledVoice() {
        var spans = VoiceSpans<Int>()
        #expect(spans.process(isVoice: false, seconds: buffer, mark: 0) == nil)
        #expect(spans.process(isVoice: true, seconds: buffer, mark: 1) == .started(1))
        #expect(spans.process(isVoice: true, seconds: buffer, mark: 2) == nil)
        #expect(spans.isVoiceActive)
    }

    @Test func gapsBetweenWordsDoNotEndIt() {
        var spans = VoiceSpans<Int>()
        _ = spans.process(isVoice: true, seconds: buffer, mark: 0)
        // 0.375 s of quiet, then the next word: still the same span.
        for mark in 1...3 {
            #expect(spans.process(isVoice: false, seconds: buffer, mark: mark) == nil)
        }
        #expect(spans.process(isVoice: true, seconds: buffer, mark: 4) == nil)
        // The quiet counts afresh after each word.
        for mark in 5...7 {
            #expect(spans.process(isVoice: false, seconds: buffer, mark: mark) == nil)
        }
        #expect(spans.isVoiceActive)
    }

    @Test func halfASecondOfQuietEndsItWhereTheQuietBegan() {
        var spans = VoiceSpans<Int>()
        _ = spans.process(isVoice: true, seconds: buffer, mark: 0)
        _ = spans.process(isVoice: true, seconds: buffer, mark: 1)
        for mark in 2...4 {
            #expect(spans.process(isVoice: false, seconds: buffer, mark: mark) == nil)
        }

        #expect(spans.process(isVoice: false, seconds: buffer, mark: 5) == .ended(start: 0, end: 2))
        #expect(!spans.isVoiceActive)
        #expect(spans.process(isVoice: false, seconds: buffer, mark: 6) == nil)
        #expect(spans.process(isVoice: true, seconds: buffer, mark: 7) == .started(7))
    }

    @Test func quietIsMeasuredInAudioNotInBuffers() {
        // A tap delivering small buffers: 31 of 1/64 s are not yet half a second.
        var small = VoiceSpans<Int>()
        _ = small.process(isVoice: true, seconds: buffer, mark: 0)
        for mark in 1...31 {
            #expect(small.process(isVoice: false, seconds: 1.0 / 64, mark: mark) == nil)
        }
        #expect(small.process(isVoice: false, seconds: 1.0 / 64, mark: 32) == .ended(start: 0, end: 1))

        // One long buffer of half a second ends it at once.
        var large = VoiceSpans<Int>()
        _ = large.process(isVoice: true, seconds: 0.5, mark: 0)
        #expect(large.process(isVoice: false, seconds: 0.5, mark: 1) == .ended(start: 0, end: 1))
    }
}

@Suite struct MicrophoneTimelineTests {
    /// A position on a 16 kHz analyzer timeline.
    func audio(_ frames: Int64) -> CMTime {
        CMTime(value: frames, timescale: 16_000)
    }

    @Test func theFirstBufferIsReportedOnceWithItsCaptureAndDeliveryTimes() throws {
        let timeline = MicrophoneTimeline()
        let captured = TimelineClock.now()

        timeline.record(frames: 4800, sampleRate: 48_000, when: AVAudioTime(hostTime: captured), audioTime: .zero, voice: nil)
        timeline.record(frames: 4800, sampleRate: 48_000, when: AVAudioTime(hostTime: captured + 1), audioTime: audio(1600), voice: nil)

        let first = try #require(timeline.takeFirstBuffer())
        #expect(first.mark == MicrophoneTimeline.Mark(hostTime: captured, audioTime: .zero))
        #expect(first.frames == 4800)
        #expect(first.sampleRate == 48_000)
        #expect(first.hasCaptureTime)
        #expect(first.callbackTime >= captured)
        #expect(timeline.takeFirstBuffer() == nil)

        // The tap was installed again: its next buffer is a first buffer too.
        timeline.reportNextBufferAsFirst()
        timeline.record(frames: 4410, sampleRate: 44_100, when: AVAudioTime(hostTime: captured + 2), audioTime: audio(3200), voice: nil)
        let again = try #require(timeline.takeFirstBuffer())
        #expect(again.mark.audioTime == audio(3200))
        #expect(again.sampleRate == 44_100)
    }

    @Test func withoutACaptureTimeTheCallbacksTimeStandsIn() throws {
        let timeline = MicrophoneTimeline()
        let before = TimelineClock.now()

        // An engine rendering offline gives a sample time but no host time.
        let when = AVAudioTime(sampleTime: 0, atRate: 48_000)
        timeline.record(frames: 4800, sampleRate: 48_000, when: when, audioTime: .zero, voice: nil)

        let first = try #require(timeline.takeFirstBuffer())
        #expect(!first.hasCaptureTime)
        #expect(first.mark.hostTime == first.callbackTime)
        #expect(first.callbackTime >= before)
    }

    @Test func voiceStartsAndEndsWhereTheDetectorHearsIt() throws {
        let activity = VoiceActivity()
        let timeline = MicrophoneTimeline()
        // 1/8 s buffers at 48 kHz: a quiet room, and someone talking.
        let quiet = [Float](repeating: 0.004, count: 6000)
        let talking = [Float](repeating: 0.05, count: 6000)
        var index: Int64 = 0
        func feed(_ samples: [Float]) {
            let reading = samples.withUnsafeBufferPointer { activity.process($0.baseAddress!, count: $0.count) }
            timeline.record(
                frames: 6000,
                sampleRate: 48_000,
                when: AVAudioTime(hostTime: 1_000 + UInt64(index)),
                audioTime: audio(index * 2000),
                voice: reading
            )
            index += 1
        }

        for _ in 0..<20 { feed(quiet) }
        // The detector wants two loud buffers in a row: voice starts at the second, buffer 21.
        for _ in 0..<3 { feed(talking) }
        #expect(timeline.takeVoiceEvents().count == 1)
        // Half a second of quiet ends it, where the quiet began: buffer 23.
        for _ in 0..<3 { feed(quiet) }
        #expect(timeline.takeVoiceEvents().isEmpty)
        feed(quiet)
        let ended = timeline.takeVoiceEvents()
        #expect(ended == [.ended(
            start: MicrophoneTimeline.Mark(hostTime: 1_021, audioTime: audio(21 * 2000)),
            end: MicrophoneTimeline.Mark(hostTime: 1_023, audioTime: audio(23 * 2000))
        )])
        #expect(timeline.takeVoiceEvents().isEmpty)
    }

    @Test func voiceStartedCarriesTheLevelAndTheNoiseFloorItBeat() throws {
        let activity = VoiceActivity()
        let timeline = MicrophoneTimeline()
        let quiet = [Float](repeating: 0.004, count: 4800)
        let talking = [Float](repeating: 0.05, count: 4800)
        for samples in Array(repeating: quiet, count: 20) + [talking, talking] {
            let reading = samples.withUnsafeBufferPointer { activity.process($0.baseAddress!, count: $0.count) }
            timeline.record(frames: 4800, sampleRate: 48_000, when: AVAudioTime(hostTime: 1_000), audioTime: .zero, voice: reading)
        }

        let events = timeline.takeVoiceEvents()
        guard case .started(_, let level, let noiseFloor)? = events.first, events.count == 1 else {
            Issue.record("expected one voice start, got \(events)")
            return
        }
        #expect(abs(level - 0.05) < 0.001)
        // The quiet room's level, nudged up a little by the first loud buffer.
        let floor = try #require(noiseFloor)
        #expect(floor > 0.004 && floor < 0.005)
        #expect(VoiceActivity.decibels(level) == -26)
    }
}
