import AVFoundation
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// What the logs say about the app's state and its audio, to tell what voice mode can and can't
/// react to when the AirPods stem is pressed. Codes and names only, never the user's words.
enum MediaDiagnostics {
    /// `ProcessInfo.systemUptime`: seconds since the device started, the clock a
    /// `RemoteCommandEvent`'s receipt is stamped on.
    static func uptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// Seconds on the uptime clock, for the logs, to the tenth of a millisecond.
    static func seconds(_ time: TimeInterval) -> String {
        String(format: "%.4f", time)
    }

    /// The milliseconds from `start` to `end`, for the logs, to the tenth.
    static func milliseconds(from start: TimeInterval, to end: TimeInterval) -> String {
        String(format: "%.1f", (end - start) * 1000)
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
