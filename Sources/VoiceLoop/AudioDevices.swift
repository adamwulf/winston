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

    /// For the logs, as `in=MicrophoneBuiltIn out=Speaker`.
    var logDescription: String {
        func kinds(_ devices: [Device]) -> String {
            devices.isEmpty ? "none" : devices.map(\.kind).joined(separator: "+")
        }
        return "in=\(kinds(inputs)) out=\(kinds(outputs))"
    }
}

/// A change of the iOS audio session's route, and whether it was a device coming or going.
package struct AudioRouteChange: Sendable {
    /// Whether a device came or went, so the route may now be on other devices than voice mode
    /// started with. Otherwise the route changed for another reason, such as the app's own
    /// category change or speaker override, and voice mode carries on.
    package var isDeviceChange: Bool
    /// Why it changed, for the logs.
    package var reason: String

    package init(isDeviceChange: Bool, reason: String) {
        self.isDeviceChange = isDeviceChange
        self.reason = reason
    }

    #if os(iOS)
    init(_ reason: AVAudioSession.RouteChangeReason) {
        switch reason {
        case .newDeviceAvailable: self.init(isDeviceChange: true, reason: "newDeviceAvailable")
        case .oldDeviceUnavailable: self.init(isDeviceChange: true, reason: "oldDeviceUnavailable")
        case .noSuitableRouteForCategory: self.init(isDeviceChange: true, reason: "noSuitableRouteForCategory")
        case .categoryChange: self.init(isDeviceChange: false, reason: "categoryChange")
        case .override: self.init(isDeviceChange: false, reason: "override")
        case .wakeFromSleep: self.init(isDeviceChange: false, reason: "wakeFromSleep")
        case .routeConfigurationChange: self.init(isDeviceChange: false, reason: "routeConfigurationChange")
        case .unknown: self.init(isDeviceChange: false, reason: "unknown")
        @unknown default: self.init(isDeviceChange: false, reason: "\(reason.rawValue)")
        }
    }
    #endif
}
