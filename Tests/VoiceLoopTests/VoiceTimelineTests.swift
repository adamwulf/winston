import AVFoundation
import CoreMedia
import Logging
import Synchronization
import Testing
@testable import VoiceLoop
import VoiceLoopTestSupport

// The `voice.timeline` log: its clock, the rule for where voice starts and ends, what the
// microphone tap records, and the lines `VoiceTimeline` writes from all of that.

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

// MARK: - The lines VoiceTimeline writes

/// A host clock the test moves by hand, in milliseconds after the session started.
private final class TestClock: Sendable {
    let start = AVAudioTime.hostTime(forSeconds: 100)
    private let current: Mutex<UInt64>

    init() {
        current = Mutex(start)
    }

    func now() -> UInt64 {
        current.withLock { $0 }
    }

    /// The host time `milliseconds` after the session started.
    func at(_ milliseconds: Int) -> UInt64 {
        start + AVAudioTime.hostTime(forSeconds: Double(milliseconds) / 1000)
    }

    func set(_ milliseconds: Int) {
        let time = at(milliseconds)
        current.withLock { $0 = time }
    }
}

/// Keeps every line a logger writes, with the metadata as strings.
private final class LineRecorder: LogHandler, Sendable {
    struct Line: Sendable {
        let message: String
        let metadata: [String: String]
    }

    private let recorded = Mutex<[Line]>([])

    var lines: [Line] { recorded.withLock { $0 } }
    var messages: [String] { lines.map(\.message) }

    /// The metadata of every line with `message`, in the order written.
    func metadata(of message: String) -> [[String: String]] {
        lines.filter { $0.message == message }.map(\.metadata)
    }

    var metadata: Logger.Metadata {
        get { [:] }
        set {}
    }

    var logLevel: Logger.Level {
        get { .trace }
        set {}
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { nil }
        set {}
    }

    func log(event: LogEvent) {
        let line = Line(message: event.message.description, metadata: (event.metadata ?? [:]).mapValues(\.description))
        recorded.withLock { $0.append(line) }
    }
}

/// A `VoiceTimeline` for session 7, writing to a recorder, on a clock the test moves.
@MainActor
private struct TimelineBed {
    let clock = TestClock()
    let recorder = LineRecorder()
    let fedAudio = FedAudioClock(sampleRate: 16_000)
    let timeline: VoiceTimeline

    init() {
        let clock = clock
        let recorder = recorder
        timeline = VoiceTimeline(
            session: 7,
            fedAudio: fedAudio,
            log: Logger(label: "test.timeline") { _ in recorder },
            now: { clock.now() }
        )
    }

    /// Feeds the analyzer `milliseconds` of 16 kHz audio.
    func feedAnalyzer(_ milliseconds: Int) {
        fedAudio.add(frames: AVAudioFrameCount(milliseconds * 16))
    }

    /// The tap hands over a 1/8 s buffer captured at `capturedMs`, starting at `audioMs` on the
    /// analyzer's timeline. The detector calls it voice or not, at -20 dBFS over a -40 dBFS floor.
    func micBuffer(capturedMs: Int, audioMs: Int, isVoice: Bool) {
        timeline.microphone.record(
            frames: 6000,
            sampleRate: 48_000,
            when: AVAudioTime(hostTime: clock.at(capturedMs)),
            audioTime: CMTime(value: CMTimeValue(audioMs * 16), timescale: 16_000),
            voice: VoiceActivity.Reading(level: 0.1, noiseFloor: 0.01, isVoice: isVoice)
        )
    }
}

@MainActor
@Suite struct VoiceTimelineLogTests {
    @Test func everyLineCarriesTheSessionAndATimeOnItsClock() {
        let bed = TimelineBed()

        bed.timeline.started(echoCancellation: true, fastResults: true, tapFramesRequested: 4096, analyzerRate: 16_000)
        bed.clock.set(40)
        bed.timeline.recognizerStarted(called: bed.clock.at(10), returned: bed.clock.at(40))
        // The tap runs 3 ms after the buffer was captured.
        bed.clock.set(53)
        bed.micBuffer(capturedMs: 50, audioMs: 0, isVoice: false)
        bed.clock.set(60)
        bed.timeline.writeRecorded()
        bed.timeline.result(.spoken("Hi", over: 0...0.5), words: 1, isFirst: true, firstWordStart: nil)
        bed.timeline.utteranceDiscarded(words: 1)

        let recorder = bed.recorder
        #expect(recorder.messages == ["timeline started", "recognizer started", "first mic buffer", "first result", "utterance discarded"])
        #expect(recorder.lines.allSatisfy { $0.metadata["session"] == "7" && $0.metadata["tMs"] != nil })
        #expect(recorder.metadata(of: "timeline started") == [[
            "tMs": "0", "session": "7", "echoCancellation": "true", "fastResults": "true",
            "tapFramesRequested": "4096", "analyzerRate": "16000",
        ]])
        #expect(recorder.metadata(of: "recognizer started") == [["tMs": "40", "session": "7", "startMs": "30"]])
        // Dated when it was captured, not when it was written.
        #expect(recorder.metadata(of: "first mic buffer") == [[
            "tMs": "50", "session": "7", "audioMs": "0", "tapFrames": "6000", "tapRate": "48000", "deliveryMs": "3",
        ]])
    }

    @Test func aFirstResultSaysHowOldItsFirstWordIsAndHowLongSinceVoiceStarted() {
        let bed = TimelineBed()
        bed.clock.set(1040)
        bed.micBuffer(capturedMs: 1000, audioMs: 1000, isVoice: true)
        bed.feedAnalyzer(5000)
        bed.clock.set(4000)

        bed.timeline.result(
            .spoken("Wait now", over: 0.5...4.9),
            words: 2,
            isFirst: true,
            firstWordStart: CMTime(value: 1200, timescale: 1000)
        )
        bed.clock.set(4500)
        bed.timeline.result(.spoken("Wait now please", over: 0.5...5.2, isFinal: true), words: 3, isFirst: false, firstWordStart: nil)

        let recorder = bed.recorder
        #expect(recorder.messages == ["first mic buffer", "voice started", "first result", "result"])
        #expect(recorder.metadata(of: "voice started") == [[
            "tMs": "1000", "session": "7", "audioMs": "1000",
            "levelDb": "-20", "floorDb": "-40", "speaking": "false", "detectMs": "3000",
        ]])
        // The word started at 1.2 s of audio, and 5 s had been fed when the result came.
        #expect(recorder.metadata(of: "first result") == [[
            "tMs": "4000", "session": "7", "audioMs": "5000",
            "rangeStartMs": "500", "rangeEndMs": "4900", "wordStartMs": "1200", "lagMs": "3800",
            "words": "2", "final": "false", "speaking": "false", "sinceVoiceMs": "3000",
        ]])
        #expect(recorder.metadata(of: "result") == [[
            "tMs": "4500", "session": "7", "audioMs": "5000", "rangeEndMs": "5200", "words": "3", "final": "true",
        ]])
    }

    @Test func aBargeInIsTimedFromTheVoiceToTheResultToTheStop() {
        let bed = TimelineBed()
        bed.clock.set(500)
        let firstAudio = bed.clock.at(650)
        bed.timeline.speechStarted(at: bed.clock.at(400), chars: 12, queued: 1) { firstAudio }
        bed.clock.set(700)
        bed.timeline.writeRecorded()
        // Adam starts talking over the reply at 1 s; the first word arrives at 3 s.
        bed.micBuffer(capturedMs: 1000, audioMs: 1000, isVoice: true)
        bed.clock.set(3000)
        bed.timeline.result(.spoken("Wait", over: 0...3), words: 1, isFirst: true, firstWordStart: nil)
        bed.timeline.bargeInDecided(words: 1)
        bed.clock.set(3004)
        bed.timeline.speechStopRequested(reason: "bargeIn")
        bed.clock.set(3012)
        bed.timeline.speechStopped(outputLatency: 0.02)

        let recorder = bed.recorder
        #expect(recorder.messages == [
            "speech started", "speech first audio", "first mic buffer", "voice started", "first result",
            "barge-in decided", "speech stop requested", "speech stopped", "barge-in timeline",
        ])
        #expect(recorder.metadata(of: "speech started") == [[
            "tMs": "500", "session": "7", "reply": "1", "chars": "12", "queued": "1", "voiceActive": "false",
        ]])
        #expect(recorder.metadata(of: "speech first audio") == [["tMs": "650", "session": "7", "reply": "1", "synthMs": "250"]])
        #expect(recorder.metadata(of: "voice started").first?["speaking"] == "true")
        #expect(recorder.metadata(of: "first result").first?["speaking"] == "true")
        #expect(recorder.metadata(of: "barge-in decided") == [[
            "tMs": "3000", "session": "7", "audioMs": "0",
            "trigger": "words", "words": "1", "replyMs": "2600", "sinceVoiceMs": "2000",
        ]])
        #expect(recorder.metadata(of: "speech stop requested") == [["tMs": "3004", "session": "7", "reason": "bargeIn", "reply": "1"]])
        #expect(recorder.metadata(of: "speech stopped") == [[
            "tMs": "3012", "session": "7", "reply": "1", "stopMs": "8", "outputLatencyMs": "20",
        ]])
        #expect(recorder.metadata(of: "barge-in timeline") == [[
            "tMs": "3012", "session": "7", "voiceToResultMs": "2000", "resultToStopMs": "12", "voiceToStopMs": "2012",
        ]])
    }

    @Test func timesThatAreNotKnownAreLeftOut() {
        let bed = TimelineBed()
        bed.timeline.speechStarted(at: bed.clock.at(0), chars: 3, queued: 0) { nil }
        // A buffer from an engine rendering offline, with no capture time.
        bed.clock.set(900)
        bed.timeline.microphone.record(
            frames: 4800, sampleRate: 48_000, when: AVAudioTime(sampleTime: 0, atRate: 48_000), audioTime: .zero, voice: nil
        )
        bed.clock.set(1000)
        // No voice was heard, and the result has no word timings.
        bed.timeline.result(.spoken("Stop", over: 0...1), words: 1, isFirst: true, firstWordStart: nil)
        bed.timeline.bargeInDecided(words: 1)
        bed.timeline.speechStopRequested(reason: "bargeIn")
        bed.clock.set(1005)
        bed.timeline.speechStopped(outputLatency: 0)

        let recorder = bed.recorder
        // The callback's own time stands in for the capture time, so there is no delay to give.
        #expect(recorder.metadata(of: "first mic buffer") == [[
            "tMs": "900", "session": "7", "audioMs": "0", "tapFrames": "4800", "tapRate": "48000",
        ]])
        let firstResult = recorder.metadata(of: "first result").first ?? [:]
        #expect(firstResult["wordStartMs"] == nil && firstResult["lagMs"] == nil && firstResult["sinceVoiceMs"] == nil)
        #expect(recorder.metadata(of: "barge-in decided").first?["sinceVoiceMs"] == nil)
        #expect(recorder.metadata(of: "barge-in timeline") == [["tMs": "1005", "session": "7", "resultToStopMs": "5"]])
        // The reply never scheduled any audio.
        #expect(!recorder.messages.contains("speech first audio"))
    }

    @Test func eachReplyIsNumberedAndVoiceIsMatchedToTheReplyPlaying() {
        let bed = TimelineBed()
        // Voice that began before a reply: written as the reply starts, it was not over a reply,
        // and the reply starts over it.
        bed.clock.set(110)
        bed.micBuffer(capturedMs: 100, audioMs: 100, isVoice: true)
        bed.clock.set(200)
        bed.timeline.speechStarted(at: bed.clock.at(150), chars: 5, queued: 1) { nil }
        bed.clock.set(900)
        bed.timeline.speechFinished(["reason": "finished", "ms": 750])
        // Half a second of quiet ends that voice.
        for index in 0..<4 {
            bed.micBuffer(capturedMs: 1000 + index * 125, audioMs: 1000 + index * 125, isVoice: false)
        }
        bed.clock.set(1600)
        bed.timeline.speechStarted(at: bed.clock.at(1600), chars: 9, queued: 0) { nil }
        // Voice over the second reply.
        bed.micBuffer(capturedMs: 1700, audioMs: 1700, isVoice: true)
        bed.clock.set(1800)
        bed.timeline.writeRecorded()

        let recorder = bed.recorder
        #expect(recorder.messages == [
            "first mic buffer", "voice started", "speech started", "speech finished",
            "voice ended", "speech started", "voice started",
        ])
        let voiceStarts = recorder.metadata(of: "voice started")
        #expect(voiceStarts.map { $0["speaking"] } == ["false", "true"])
        let replies = recorder.metadata(of: "speech started")
        #expect(replies.map { $0["reply"] } == ["1", "2"])
        #expect(replies.map { $0["voiceActive"] } == ["true", "false"])
        #expect(recorder.metadata(of: "speech finished") == [[
            "tMs": "900", "session": "7", "reply": "1", "reason": "finished", "ms": "750",
        ]])
        #expect(recorder.metadata(of: "voice ended") == [["tMs": "1000", "session": "7", "audioMs": "1000", "voicedMs": "900"]])
    }

    @Test func aTapReinstalledBeforeItsFirstBufferWasWrittenReportsBothFirstBuffers() {
        let bed = TimelineBed()
        bed.clock.set(30)
        bed.timeline.microphone.record(
            frames: 4096, sampleRate: 48_000, when: AVAudioTime(hostTime: bed.clock.at(20)), audioTime: .zero, voice: nil
        )

        // As on the iPhone, the engine stops and restarts before the first 100 ms poll.
        bed.timeline.willReinstallTap()
        bed.clock.set(85)
        bed.timeline.microphone.record(
            frames: 4410, sampleRate: 44_100, when: AVAudioTime(hostTime: bed.clock.at(70)), audioTime: .zero, voice: nil
        )
        bed.clock.set(100)
        bed.timeline.writeRecorded()

        #expect(bed.recorder.metadata(of: "first mic buffer") == [
            ["tMs": "20", "session": "7", "audioMs": "0", "tapFrames": "4096", "tapRate": "48000", "deliveryMs": "10"],
            ["tMs": "70", "session": "7", "audioMs": "0", "tapFrames": "4410", "tapRate": "44100", "deliveryMs": "15"],
        ])
    }

    @Test func aFirstBufferScheduledWhileTheReplyIsBeingStoppedIsStillWritten() {
        let bed = TimelineBed()
        var firstAudio: UInt64?
        bed.timeline.speechStarted(at: bed.clock.at(0), chars: 40, queued: 0) { firstAudio }
        bed.clock.set(100)
        bed.timeline.speechStopRequested(reason: "stopped")

        // The synthesizer schedules its first buffer before the playback is cancelled.
        firstAudio = bed.clock.at(102)
        bed.clock.set(105)
        bed.timeline.speechStopped(outputLatency: 0)

        let recorder = bed.recorder
        #expect(recorder.messages == ["speech started", "speech stop requested", "speech first audio", "speech stopped"])
        #expect(recorder.metadata(of: "speech first audio") == [["tMs": "102", "session": "7", "reply": "1", "synthMs": "102"]])
        // Timed from when the player stopped, before the late line was written.
        #expect(recorder.metadata(of: "speech stopped").first?["stopMs"] == "5")
    }
}
