import AVFoundation
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// What the logs say about the app's state and its audio, to tell what voice mode can and can't
/// react to when the AirPods stem is pressed. Codes and names only, never the user's words.
///
/// Times only as elapsed milliseconds, never an uptime: see `MediaLogClock`.
enum MediaDiagnostics {
    /// `ProcessInfo.systemUptime`: seconds since the device started, the clock a
    /// `RemoteCommandEvent`'s receipt is stamped on. Only for measuring the time between two
    /// events: the logs never write it (see `MediaLogClock`).
    static func uptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// The milliseconds from `start` to `end`, two uptimes, for the logs, to the tenth.
    static func milliseconds(from start: TimeInterval, to end: TimeInterval) -> String {
        String(format: "%.1f", (end - start) * 1000)
    }

    /// The furthest a remote command's timestamp may be from its receipt, in seconds, and still
    /// be taken as on the uptime clock.
    static let eventTimestampTolerance: TimeInterval = 60

    /// Whether `event`'s timestamp can be taken as on the uptime clock: it is positive, and within
    /// `eventTimestampTolerance` of the event's receipt. Apple doesn't say what clock it's on. A
    /// timestamp of 0 (even within a minute of the device starting) or on another clock would
    /// give the uptime away in the time from it to an uptime, so the logs leave those times out.
    static func isOnUptimeClock(_ event: RemoteCommandEvent) -> Bool {
        event.timestamp > 0 && abs(event.receivedUptime - event.timestamp) <= eventTimestampTolerance
    }

    /// The times of a remote command's log lines, all elapsed: since voice mode started
    /// (`sinceVoiceModeStartMs`, at `handled`, when the main actor took it; left out without a
    /// `clock`), from receipt to then (`receiptToMainMs`), and from the event's own timestamp to
    /// receipt (`eventToReceiptMs`) when `eventTimestampOnUptime` says it can be measured. With
    /// `applied`, the uptimes at which `setInputMuted` returned and `inputMuteChanged` had run,
    /// also the time to each from receipt (`receiptToSetMutedMs`, `receiptToAppliedMs`) and from
    /// the event's timestamp (`eventToSetMutedMs`, `eventToAppliedMs`), the same way.
    static func remoteCommandTimes(
        _ event: RemoteCommandEvent,
        handled: TimeInterval,
        applied: (setMutedReturned: TimeInterval, muteChanged: TimeInterval)? = nil,
        clock: MediaLogClock?
    ) -> [String: CustomStringConvertible] {
        let onUptimeClock = isOnUptimeClock(event)
        var fields: [String: CustomStringConvertible] = [
            "receiptToMainMs": milliseconds(from: event.receivedUptime, to: handled),
            "eventTimestampOnUptime": onUptimeClock,
        ]
        fields["sinceVoiceModeStartMs"] = clock?.milliseconds(at: handled)
        if onUptimeClock {
            fields["eventToReceiptMs"] = milliseconds(from: event.timestamp, to: event.receivedUptime)
        }
        guard let applied else { return fields }
        fields["receiptToSetMutedMs"] = milliseconds(from: event.receivedUptime, to: applied.setMutedReturned)
        fields["receiptToAppliedMs"] = milliseconds(from: event.receivedUptime, to: applied.muteChanged)
        if onUptimeClock {
            fields["eventToSetMutedMs"] = milliseconds(from: event.timestamp, to: applied.setMutedReturned)
            fields["eventToAppliedMs"] = milliseconds(from: event.timestamp, to: applied.muteChanged)
        }
        return fields
    }

    /// Whether the app is active, inactive (on iOS, say, under Control Center) or in the
    /// background. On the Mac, active, hidden or inactive.
    @MainActor static var appState: String {
        #if os(iOS)
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
        #else
        let app = NSRunningApplication.current
        return app.isActive ? "active" : app.isHidden ? "hidden" : "inactive"
        #endif
    }

    #if os(iOS)
    /// The audio session as it is now: category, mode, options, sample rate, IO buffer duration,
    /// the route's port types (`BluetoothHFP`, `BluetoothA2DPOutput`, `BluetoothLE`, and so on),
    /// and whether other audio plays and should be silenced.
    static func sessionContext(_ session: AVAudioSession = .sharedInstance()) -> [String: CustomStringConvertible] {
        let route = session.currentRoute
        func portTypes(_ ports: [AVAudioSessionPortDescription]) -> String {
            ports.isEmpty ? "none" : ports.map(\.portType.rawValue).joined(separator: "+")
        }
        return [
            "category": session.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: ""),
            "mode": session.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: ""),
            "options": optionNames(session.categoryOptions),
            "sampleRate": session.sampleRate,
            "ioBufferMs": String(format: "%.1f", session.ioBufferDuration * 1000),
            "inputs": portTypes(route.inputs),
            "outputs": portTypes(route.outputs),
            "otherAudioPlaying": session.isOtherAudioPlaying,
            "silenceSecondaryAudioHint": session.secondaryAudioShouldBeSilencedHint,
        ]
    }

    /// The category options by name, as `allowBluetoothHFP,defaultToSpeaker`, and any bits left
    /// over in hex. By raw value, since some are newer than the app's deployment target.
    static func optionNames(_ options: AVAudioSession.CategoryOptions) -> String {
        let named: [(UInt, String)] = [
            (0x1, "mixWithOthers"),
            (0x2, "duckOthers"),
            (0x4, "allowBluetoothHFP"),
            (0x8, "defaultToSpeaker"),
            // `interruptSpokenAudioAndMixWithOthers` is 0x11: this bit and `mixWithOthers`.
            (0x10, "interruptSpokenAudio"),
            (0x20, "allowBluetoothA2DP"),
            (0x40, "allowAirPlay"),
            (0x80, "overrideMutedMicrophoneInterruption"),
            (1 << 18, "farFieldInput"),
            (1 << 19, "bluetoothHighQualityRecording"),
        ]
        var rest = options.rawValue
        var names: [String] = []
        for (bit, name) in named where rest & bit != 0 {
            names.append(name)
            rest &= ~bit
        }
        if rest != 0 {
            names.append("0x" + String(rest, radix: 16))
        }
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }
    #endif
}

/// Where the media logs' times count from: voice mode's start, on the uptime clock. The logs
/// give a time as the milliseconds since then (`sinceVoiceModeStartMs`) or between two events,
/// never as an uptime. An uptime is the time since the device started, which must not leave
/// the device (the privacy manifest's reason 35F9.1 for the system boot time), and the logs do
/// leave it, with Export Debug Logs.
struct MediaLogClock: Sendable, Equatable {
    /// The uptime at voice mode's start.
    let start: TimeInterval

    /// `start` is for tests: by default, now.
    init(start: TimeInterval = MediaDiagnostics.uptime()) {
        self.start = start
    }

    /// The milliseconds from voice mode's start to `uptime`, for the logs, to the tenth.
    func milliseconds(at uptime: TimeInterval) -> String {
        MediaDiagnostics.milliseconds(from: start, to: uptime)
    }
}
