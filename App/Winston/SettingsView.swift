import SwiftUI
import VoiceLoop
import WinstonLogging

/// The pause threshold, the voice and its speed, whether other audio pauses, debug logs, and Log out. AppModel persists the settings and applies them to the
/// voice loop. A sheet on iOS; the standard Settings window on macOS.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingLogOut = false
    #if os(iOS)
    private static let log = Logger(label: "app.settings")
    @State private var isExportingLogs = false
    @State private var exportedLogs: SharedFile?
    @State private var exportError: String?
    #endif
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
        .sheet(item: $exportedLogs) { file in
            ShareSheet(url: file.url) {
                // Shared or cancelled, the temporary zip isn't needed afterwards. (If the sheet is
                // swiped away instead, the next export empties the folder.)
                removeExportedLogs(file.url)
                exportedLogs = nil
            }
            .presentationDetents([.medium, .large])
        }
        .alert("Couldn't Export Debug Logs", isPresented: showingExportError) {
            Button("OK") {}
        } message: {
            Text(exportError ?? "")
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
                .onChange(of: model.voiceIdentifier) {
                    model.previewVoice()
                }
                LabeledContent("Speaking speed") {
                    Text(speedDescription)
                }
                Slider(value: $model.speechRate, in: VoiceLoop.speechRates, step: 0.05) {
                    Text("Speaking speed")
                } minimumValueLabel: {
                    Image(systemName: "tortoise")
                        .accessibilityLabel("Slower")
                } maximumValueLabel: {
                    Image(systemName: "hare")
                        .accessibilityLabel("Faster")
                } onEditingChanged: { isEditing in
                    if !isEditing {
                        model.previewVoice()
                    }
                }
                .labelsHidden()
            } header: {
                Text("Voice Mode")
            } footer: {
                Text("Voice mode sends what you say once you've paused this long, or twice as long when you stop mid-sentence.")
            }
            Section {
                Toggle("Pause Other Audio", isOn: $model.pausesOtherAudio)
            } footer: {
                Text("Turn this off to keep music and other audio playing during voice mode.")
            }
            Section("Debug Logs") {
                #if os(iOS)
                Button("Export Debug Logs…", action: exportLogs)
                    .disabled(isExportingLogs)
                #else
                Button("Export Debug Logs…") {
                    Task { await DebugLogs.export() }
                }
                Button("Open Log Folder") {
                    DebugLogs.openLogFolder()
                }
                #endif
            }
            // On the Mac the Settings window opens before login too; only offer Log Out once logged in.
            if model.authState == .ready {
                Section {
                    Button("Log Out", role: .destructive) {
                        confirmingLogOut = true
                    }
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

    #if os(iOS)
    /// Zips the Logs folder, then offers the zip in the share sheet. Failures are logged and shown in an alert.
    private func exportLogs() {
        isExportingLogs = true
        Task {
            defer { isExportingLogs = false }
            do {
                exportedLogs = SharedFile(url: try await LogExporter.exportLogs())
            } catch {
                // Codes only: a file error's description can name the folder's path.
                Self.log.error("debug log export failed", error.logCodes())
                exportError = error.localizedDescription
            }
        }
    }

    private func removeExportedLogs(_ zip: URL) {
        do {
            try FileManager.default.removeItem(at: zip)
        } catch {
            Self.log.warning("removing the exported zip failed", error.logCodes())
        }
    }

    private var showingExportError: Binding<Bool> {
        Binding {
            exportError != nil
        } set: { isShowing in
            if !isShowing { exportError = nil }
        }
    }
    #endif

    /// The speech rate scale isn't linear, so the slider shows no number, only how it compares to normal.
    /// The tolerance absorbs rounding in the slider's steps.
    private var speedDescription: String {
        let difference = model.speechRate - VoiceLoop.defaultSpeechRate
        if difference < -0.01 { return "Slower" }
        if difference > 0.01 { return "Faster" }
        return "Normal"
    }

    private func label(for voice: VoiceOption) -> String {
        switch voice.quality {
        case .premium: "\(voice.name) (Premium)"
        case .enhanced: "\(voice.name) (Enhanced)"
        case .standard: voice.name
        }
    }
}
