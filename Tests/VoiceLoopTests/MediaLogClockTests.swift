import Foundation
import Testing
@testable import VoiceLoop

// The mute and remote command logs give times only as elapsed milliseconds, never as an uptime,
// which counts from the device's start and must not leave it. The uptimes here are over 300,000
// seconds, and every time measured between them under 100, so a field holding an uptime, or a
// time from 0 or another clock to one, shows.

@Suite struct MediaLogClockTests {
    /// Voice mode started at this uptime, in seconds: about 3.5 days after the device started.
    let start = 301_234.5

    /// Whether any number in `fields` is 100,000 or more: an uptime of these tests in seconds, or
    /// over 100 seconds in milliseconds, which no time measured here comes near. Every value that
    /// isn't a number must be `true` or `false`.
    private func holdsAnUptime(_ fields: [String: CustomStringConvertible]) -> Bool {
        fields.values.contains { value in
            guard let number = Double(value.description) else {
                return !["true", "false"].contains(value.description)
            }
            return !(abs(number) < 100_000)
        }
    }

    @Test func countsMillisecondsSinceVoiceModeStarted() {
        let clock = MediaLogClock(start: start)

        #expect(clock.milliseconds(at: start) == "0.0")
        #expect(clock.milliseconds(at: start + 1.25) == "1250.0")
        #expect(clock.milliseconds(at: start + 0.0034) == "3.4")
    }

    @Test func aRemoteCommandOnTheUptimeClockGivesItsTimesFromVoiceModesStartAndFromTheEvent() {
        let clock = MediaLogClock(start: start)
        let event = RemoteCommandEvent(name: "togglePlayPause", command: .togglePlayPause, timestamp: 301_245.5, receivedUptime: 301_245.512)

        let fields = MediaDiagnostics.remoteCommandTimes(event, handled: 301_245.515, clock: clock)
        #expect(!holdsAnUptime(fields))
        #expect(fields.mapValues(\.description) == [
            "sinceVoiceModeStartMs": "11015.0",
            "eventToReceiptMs": "12.0",
            "receiptToMainMs": "3.0",
            "eventTimestampOnUptime": "true",
        ])
    }

    @Test func theMuteTimesCountFromReceiptAndFromTheEvent() {
        let clock = MediaLogClock(start: start)
        let event = RemoteCommandEvent(name: "play", command: .play, timestamp: 301_245.5, receivedUptime: 301_245.512)

        let fields = MediaDiagnostics.remoteCommandTimes(
            event,
            handled: 301_245.515,
            applied: (setMutedReturned: 301_245.52, muteChanged: 301_245.5225),
            clock: clock
        )
        #expect(!holdsAnUptime(fields))
        #expect(fields.mapValues(\.description) == [
            "sinceVoiceModeStartMs": "11015.0",
            "eventToReceiptMs": "12.0",
            "receiptToMainMs": "3.0",
            "eventTimestampOnUptime": "true",
            "receiptToSetMutedMs": "8.0",
            "receiptToAppliedMs": "10.5",
            "eventToSetMutedMs": "20.0",
            "eventToAppliedMs": "22.5",
        ])
    }

    /// With a timestamp of 0, or on another clock, the time from it to an uptime would be the
    /// uptime, or would give it away, so only the times from receipt are logged.
    @Test func aTimestampFarFromItsReceiptIsLeftOutOfTheTimes() {
        let clock = MediaLogClock(start: start)
        let timestamps: [TimeInterval] = [0, 12_345, 301_245.512 + 120, -301_245, .nan, .infinity]
        for timestamp in timestamps {
            let event = RemoteCommandEvent(name: "pause", command: .pause, timestamp: timestamp, receivedUptime: 301_245.512)
            let fields = MediaDiagnostics.remoteCommandTimes(
                event,
                handled: 301_245.515,
                applied: (setMutedReturned: 301_245.52, muteChanged: 301_245.5225),
                clock: clock
            )
            #expect(!holdsAnUptime(fields))
            #expect(fields.mapValues(\.description) == [
                "sinceVoiceModeStartMs": "11015.0",
                "receiptToMainMs": "3.0",
                "eventTimestampOnUptime": "false",
                "receiptToSetMutedMs": "8.0",
                "receiptToAppliedMs": "10.5",
            ], "timestamp \(timestamp)")
        }
    }

    @Test func aTimestampWithinTheToleranceOfItsReceiptIsMeasured() {
        let receipt = 301_245.0
        let early = RemoteCommandEvent(name: "play", command: .play, timestamp: receipt - MediaDiagnostics.eventTimestampTolerance, receivedUptime: receipt)
        let late = RemoteCommandEvent(name: "play", command: .play, timestamp: receipt + 0.002, receivedUptime: receipt)
        let tooEarly = RemoteCommandEvent(name: "play", command: .play, timestamp: receipt - MediaDiagnostics.eventTimestampTolerance - 0.5, receivedUptime: receipt)

        #expect(MediaDiagnostics.isOnUptimeClock(early))
        // Stamped a moment after its receipt, as by a clock read a hair apart: still measured.
        #expect(MediaDiagnostics.isOnUptimeClock(late))
        #expect(MediaDiagnostics.remoteCommandTimes(late, handled: receipt, clock: nil)["eventToReceiptMs"]?.description == "-2.0")
        #expect(!MediaDiagnostics.isOnUptimeClock(tooEarly))
    }

    @Test func withoutAClockThereIsNoTimeSinceVoiceModeStarted() {
        let event = RemoteCommandEvent(name: "nextTrack", command: nil, timestamp: 301_245.5, receivedUptime: 301_245.512)

        let fields = MediaDiagnostics.remoteCommandTimes(event, handled: 301_245.515, clock: nil)
        #expect(fields["sinceVoiceModeStartMs"] == nil)
        #expect(!holdsAnUptime(fields))
        #expect(fields.mapValues(\.description) == [
            "eventToReceiptMs": "12.0",
            "receiptToMainMs": "3.0",
            "eventTimestampOnUptime": "true",
        ])
    }
}
