import AVFoundation
import Testing
@testable import VoiceLoop

// The `voice.echo` log's rate limit on its level lines, and its before and after of the
// engine's state at a configuration change.

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
}
