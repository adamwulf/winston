#if os(iOS)
import AVFoundation
#endif

/// The audio devices voice mode listens and speaks through: on iOS the audio session's route, on
/// the Mac the system's default input and output. Voice mode ends when they change while it runs,
/// as when AirPods connect or are taken out (see `VoiceLoop.onStoppedForDeviceChange`).
package struct AudioDevices: Equatable, Sendable {
    package struct Device: Equatable, Sendable {
        /// Tells devices apart: a port's UID on iOS, a device ID on the Mac.
        package var id: String
        /// What the logs show for it, without its name: a port's type on iOS, such as
        /// `BluetoothHFP`, and the device ID on the Mac.
        package var kind: String

        package init(id: String, kind: String) {
            self.id = id
            self.kind = kind
        }
    }

    package var inputs: [Device]
    package var outputs: [Device]

    package init(inputs: [Device], outputs: [Device]) {
        self.inputs = inputs
        self.outputs = outputs
    }

    #if os(iOS)
    /// The ports of an iOS audio route.
    init(_ route: AVAudioSessionRouteDescription) {
        func devices(_ ports: [AVAudioSessionPortDescription]) -> [Device] {
            ports.map { Device(id: $0.uid, kind: $0.portType.rawValue) }
        }
        self.init(inputs: devices(route.inputs), outputs: devices(route.outputs))
    }
    #endif

    /// For the logs, as `in=MicrophoneBuiltIn out=Speaker`.
    var logDescription: String {
        func kinds(_ devices: [Device]) -> String {
            devices.isEmpty ? "none" : devices.map(\.kind).joined(separator: "+")
        }
        return "in=\(kinds(inputs)) out=\(kinds(outputs))"
    }
}

/// A change of the iOS audio session's route: why, and the route on each side of it.
package struct AudioRouteChange: Sendable {
    /// Whether a device came or went. Otherwise the route changed for another reason, such as
    /// the app's own category change or speaker override, and voice mode carries on.
    package var isDeviceChange: Bool
    /// Why it changed, for the logs.
    package var reason: String
    /// The route before the change, as the notification reported it.
    package var previous: AudioDevices
    /// The route after the change, read as the notification was posted, not later, when the
    /// main actor gets to it and the route may have changed again.
    package var current: AudioDevices

    package init(isDeviceChange: Bool, reason: String, previous: AudioDevices, current: AudioDevices) {
        self.isDeviceChange = isDeviceChange
        self.reason = reason
        self.previous = previous
        self.current = current
    }

    #if os(iOS)
    init(_ reason: AVAudioSession.RouteChangeReason, previous: AudioDevices, current: AudioDevices) {
        let (isDeviceChange, name): (Bool, String) = switch reason {
        case .newDeviceAvailable: (true, "newDeviceAvailable")
        case .oldDeviceUnavailable: (true, "oldDeviceUnavailable")
        case .noSuitableRouteForCategory: (true, "noSuitableRouteForCategory")
        case .categoryChange: (false, "categoryChange")
        case .override: (false, "override")
        case .wakeFromSleep: (false, "wakeFromSleep")
        case .routeConfigurationChange: (false, "routeConfigurationChange")
        case .unknown: (false, "unknown")
        @unknown default: (false, "\(reason.rawValue)")
        }
        self.init(isDeviceChange: isDeviceChange, reason: name, previous: previous, current: current)
    }
    #endif
}
