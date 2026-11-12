import SwiftUI
import VoiceLoop

/// The pause threshold, the voice, and Log out. `ContentView` applies the stored values to the voice loop.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(StorageKey.pauseThreshold) private var pauseThreshold = 1.2
    @AppStorage(StorageKey.voiceIdentifier) private var voiceIdentifier = ""
    @State private var confirmingLogOut = false
    private let voices = VoiceLoop.availableVoices()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Pause before sending") {
                        Text("\(pauseThreshold.formatted(.number.precision(.fractionLength(1)))) s")
                    }
                    Slider(value: $pauseThreshold, in: 0.8...3.0, step: 0.1)
                    Picker("Voice", selection: $voiceIdentifier) {
                        Text("Default").tag("")
                        ForEach(voices) { voice in
                            Text(label(for: voice)).tag(voice.id)
                        }
                    }
                } header: {
                    Text("Voice Mode")
                } footer: {
                    Text("Voice mode sends what you say once you've paused this long.")
                }
                Section {
                    Button("Log Out", role: .destructive) {
                        confirmingLogOut = true
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Log out of Telegram?", isPresented: $confirmingLogOut) {
                Button("Log Out", role: .destructive) {
                    dismiss()
                    Task { await model.logOut() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }

    private func label(for voice: VoiceOption) -> String {
        switch voice.quality {
        case .premium: "\(voice.name) (Premium)"
        case .enhanced: "\(voice.name) (Enhanced)"
        case .standard: voice.name
        }
    }
}
