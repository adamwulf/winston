import AVFoundation
import Testing
@testable import VoiceLoop

// The `voice.echo` log's rate limit on its level lines, its before and after of the engine's
// state at a configuration change, the microphone readings the tap hands over, and how a
// reply counts them.

@Suite struct EchoLogTests {
    @Test func theRateLimiterLetsAnEventThroughAtMostOncePerInterval() {
        let start = AVAudioTime.hostTime(forSeconds: 100)
        func at(_ milliseconds: Int) -> UInt64 {
            start + AVAudioTime.hostTime(forSeconds: Double(milliseconds) / 1000)
        }
        var limiter = RateLimiter(interval: 0.25)
        func allows(_ milliseconds: Int) -> Bool {
            limiter.allows(at: at(milliseconds))
        }

        #expect(allows(0))
        #expect(!allows(100))
        #expect(!allows(240))
        // Polled every 100 ms, the next goes through at 300 ms; the interval counts from it.
        #expect(allows(300))
        #expect(!allows(540))
        #expect(allows(560))

        // A reply starting at 1000 ms: its first level line comes an interval after.
        limiter.restart(at: at(1000))
        #expect(!allows(1240))
        #expect(allows(1260))
    }

    @Test func aConfigurationChangeLineGivesEveryValueAndWhatChangedFrom() {
        let before = EngineAudioState(values: [
            "vpInput": "true",
            "tapFormat": "48000/1",
            "outputFormat": "48000/1",
            "formatsMatch": "true",
            "running": "true",
        ])
        let after = EngineAudioState(values: [
            "vpInput": "true",
            "tapFormat": "44100/2",
            "outputFormat": "48000/1",
            "formatsMatch": "false",
            "running": "false",
            "ioBufferMs": "21.3",
        ])

        #expect(after.changes(from: before) == ["formatsMatch", "ioBufferMs", "running", "tapFormat"])
        let fields = after.fields(changedFrom: before).mapValues(\.description)
        #expect(fields == [
            "vpInput": "true",
            "tapFormat": "44100/2",
            "tapFormatBefore": "48000/1",
            "outputFormat": "48000/1",
            "formatsMatch": "false",
            "formatsMatchBefore": "true",
            "running": "false",
            "runningBefore": "true",
            "ioBufferMs": "21.3",
            "ioBufferMsBefore": "none",
            "changed": "formatsMatch,ioBufferMs,running,tapFormat",
        ])
        #expect(after.fields(changedFrom: after)["changed"]?.description == "none")
    }

    @Test func theTapHandsOverWholeReadingsInOrderAndCountsWhatDidNotFit() {
        let levels = MicrophoneLevels()
        func record(_ samples: [Float], at captureTime: UInt64) {
            samples.withUnsafeBufferPointer { buffer in
                levels.record(buffer.baseAddress!, count: buffer.count, capturedAt: captureTime, duration: 4)
            }
        }

        record([0.5, -0.5, 0.5, -0.5], at: 10)
        record([0, 0, 0, -0.25], at: 20)
        let first = levels.drain()
        #expect(first.readings == [
            MicrophoneLevels.Reading(captureTime: 10, duration: 4, rms: 0.5, peak: 0.5),
            MicrophoneLevels.Reading(captureTime: 20, duration: 4, rms: 0.125, peak: 0.25),
        ])
        #expect(first.dropped == 0)
        #expect(levels.drain().readings.isEmpty)

        // An interleaved two-channel buffer: only the first channel is measured, every other
        // sample.
        [0.5, 9, -0.5, 9, 0.5, -9, -0.5, 9].withUnsafeBufferPointer { buffer in
            levels.record(buffer.baseAddress!, count: 4, stride: 2, capturedAt: 30, duration: 4)
        }
        #expect(levels.drain().readings == [MicrophoneLevels.Reading(captureTime: 30, duration: 4, rms: 0.5, peak: 0.5)])

        // Two more than fit while nothing is taken: the newest two are dropped, and counted.
        for time in 0..<UInt64(MicrophoneLevels.capacity + 2) {
            record([0.1], at: 100 + time)
        }
        let full = levels.drain()
        #expect(full.readings.count == MicrophoneLevels.capacity)
        #expect(full.readings.first?.captureTime == 100)
        #expect(full.readings.last?.captureTime == 100 + UInt64(MicrophoneLevels.capacity) - 1)
        #expect(full.dropped == 2)
        #expect(levels.drain().dropped == 0)
    }

    @Test func aReplyCountsBuffersBeforeItCouldBeHeardApartFromThoseAfter() {
        /// A buffer 100 host time units long.
        func reading(at captureTime: UInt64, rms: Float) -> MicrophoneLevels.Reading {
            MicrophoneLevels.Reading(captureTime: captureTime, duration: 100, rms: rms, peak: rms * 2)
        }
        var levels = ReplyLevels(started: 1000)

        // Before the setup: no reply's. Before its first buffer was scheduled: loud room noise,
        // say a cough during the render.
        levels.add(reading(at: 900, rms: 0.5), playbackFrom: nil)
        levels.add(reading(at: 1100, rms: 0.1), playbackFrom: nil)
        // Taken once it could be heard from 1500 (scheduled, plus the output's latency): one
        // buffer that ended before, one that spans it, and two after.
        levels.add(reading(at: 1350, rms: 0.01), playbackFrom: 1500)
        levels.add(reading(at: 1450, rms: 0.05), playbackFrom: 1500)
        levels.add(reading(at: 1550, rms: 0.001), playbackFrom: 1500)
        levels.add(reading(at: 1650, rms: 0.002), playbackFrom: 1500)

        #expect(levels.pre.buffers == 2)
        #expect(levels.pre.rmsDb == -20)
        #expect(levels.onset.buffers == 1)
        #expect(levels.onset.rmsDb == -26)
        #expect(levels.playback.buffers == 2)
        #expect(levels.playback.rmsDb == -54)
        #expect(levels.playback.sampleDb == -48)

        let window = levels.takeWindow()
        #expect(window == levels.playback)
        #expect(levels.takeWindow() == nil)
        levels.add(reading(at: 1750, rms: 0.0001), playbackFrom: 1500)
        #expect(levels.takeWindow()?.buffers == 1)
        #expect(levels.playback.buffers == 3)

        // It ends at 1850. A buffer captured before the end, handed over after it, still counts;
        // one captured after it doesn't, and shows every earlier one has come.
        levels.close(at: 1850)
        levels.add(reading(at: 1800, rms: 0.3), playbackFrom: 1500)
        #expect(!levels.hasReadingAfterEnd)
        levels.add(reading(at: 1900, rms: 0.9), playbackFrom: 1500)
        #expect(levels.hasReadingAfterEnd)
        #expect(levels.playback.buffers == 4)
        #expect(levels.playback.rmsDb == -10)
        // Every buffer from the setup to the end, whichever part it fell in.
        #expect(levels.whole.buffers == 7)

        // Unsplit, for a reply whose playback's latency is unknown: only the whole reply's.
        var unsplit = ReplyLevels(started: 1000)
        unsplit.addUnsplit(reading(at: 1100, rms: 0.1))
        unsplit.addUnsplit(reading(at: 1600, rms: 0.01))
        #expect(unsplit.whole.buffers == 2)
        #expect(unsplit.pre.buffers == 0 && unsplit.onset.buffers == 0 && unsplit.playback.buffers == 0)
    }
}
