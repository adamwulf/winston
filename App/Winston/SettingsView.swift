import SwiftUI
import VoiceLoop

/// The pause threshold, the voice, and Log out. AppModel persists the settings and applies them to the voice loop.
/// A sheet on iOS; the standard Settings window on macOS.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingLogOut = false
    private let voices = VoiceLoop.availableVoices()

    var body: some View {
        #if os(iOS)
        NavigationStack {
            form
                .navigationTitle("Settings")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #else
        form
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
        #endif
    }

    private var form: some View {
        @Bindable var model = model
        return Form {
            Section {
                LabeledContent("Pause before sending") {
                    Text("\(model.pauseThreshold.formatted(.number.precision(.fractionLength(1)))) s")
                }
                Slider(value: $model.pauseThreshold, in: 0.8...3.0, step: 0.1)
                Picker("Voice", selection: $model.voiceIdentifier) {
                    Text("Default").tag(String?.none)
                    ForEach(voices) { voice in
                        Text(label(for: voice)).tag(Optional(voice.id))
                    }
                }
            } header: {
                Text("Voice Mode")
            } footer: {
                Text("Voice mode sends what you say once you've paused this long, or twice as long when you stop mid-sentence.")
            }
            Section {
                Button("Log Out", role: .destructive) {
                    confirmingLogOut = true
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Log out of Telegram?", isPresented: $confirmingLogOut) {
            Button("Log Out", role: .destructive) {
                dismiss()
                Task { await model.logOut() }
            }
        }
    }

    private func label(for voice: VoiceOption) -> String {
        switch voice.quality {
        case .premium: "\(voice.name) (Premium)"
        case .enhanced: "\(voice.name) (Enhanced)"
        case .standard: voice.name
        }
    }
}
