/// The audio devices voice mode listens and speaks through: on iOS the audio session's route, on
/// the Mac the system's default input and output. Voice mode ends when they change while it runs,
/// as when AirPods connect or are taken out (see `VoiceEnvironment.audioDeviceChanges`).
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
