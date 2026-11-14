import SwiftUI
import VoiceLoop
import WinstonCore
import WinstonLogging

/// The pause threshold, the voice with its speed and pitch, the Kokoro voices' model, whether other audio pauses, debug logs, and Log out. AppModel persists the settings and applies them to the
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
    private var voices: [VoiceOption] { model.voiceLoop.voices }

    /// The picker shows the voice the loop speaks with: a chosen voice that isn't on offer in
    /// this language shows as Default, though it stays saved for when it is on offer again.
    private var voiceSelection: Binding<String?> {
        Binding {
            model.voiceLoop.chosenVoice?.id
        } set: { id in
            model.voiceIdentifier = id
        }
    }

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
                LogExporter.remove(file.url)
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
                Picker("Voice", selection: voiceSelection) {
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
                LabeledContent("Pitch") {
                    Text(pitchDescription)
                }
                // 1/16 is exact in binary, so every step, normal pitch included, is an exact value.
                Slider(value: $model.speechPitch, in: VoiceLoop.speechPitches, step: 0.0625) {
                    Text("Pitch")
                } minimumValueLabel: {
                    Image(systemName: "arrow.down")
                        .accessibilityLabel("Lower")
                } maximumValueLabel: {
                    Image(systemName: "arrow.up")
                        .accessibilityLabel("Higher")
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
            if voices.contains(where: { $0.engine == .kokoro }) {
                Section {
                    LabeledContent("Voice model") {
                        kokoroModelStatus
                    }
                    // Its own row, full width under the status, like the sliders under theirs.
                    if case .downloading(let progress) = model.voiceLoop.kokoroModelState, progress < 1 {
                        ProgressView(value: progress) {
                            Text("Download progress")
                        }
                        .labelsHidden()
                    }
                } header: {
                    Text("Kokoro Voices")
                } footer: {
                    Text("Kokoro voices are neural voices that run on this device. The first time you pick one, their model downloads: about 410 MB. Until it's ready, the best system voice speaks. The model is removed after a day without a Kokoro voice.")
                }
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

    /// Like the speed, the pitch shows only how it compares to the voice's own. The slider's step lands
    /// exactly on normal, so no tolerance is needed.
    private var pitchDescription: String {
        if model.speechPitch < VoiceLoop.defaultSpeechPitch { return "Lower" }
        if model.speechPitch > VoiceLoop.defaultSpeechPitch { return "Higher" }
        return "Normal"
    }

    private func label(for voice: VoiceOption) -> String {
        if voice.engine == .kokoro {
            return "\(voice.name) (Kokoro)"
        }
        return switch voice.quality {
        case .premium: "\(voice.name) (Premium)"
        case .enhanced: "\(voice.name) (Enhanced)"
        case .standard: voice.name
        }
    }

    /// Where the Kokoro model is: its size before anything has asked for it, the download's
    /// percentage (its progress bar is a row of its own), ready with a button that plays a
    /// sample, or failed with a retry.
    @ViewBuilder
    private var kokoroModelStatus: some View {
        switch model.voiceLoop.kokoroModelState {
        case .notLoaded:
            Text("About 410 MB")
        case .loading, .downloading(progress: 1...):
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Loading…")
            }
        case .downloading(let progress):
            // The progress bar is a row of its own, below.
            Text("Downloading \(progress.formatted(.percent.precision(.fractionLength(0))))")
                .monospacedDigit()
        case .ready:
            HStack {
                // Not a Label: in an iOS Form, a Label as LabeledContent's value is styled as
                // a row of its own and makes the row much taller.
                Image(systemName: "checkmark.circle.fill")
                    .accessibilityHidden(true)
                Text("Ready")
                // Picking a Kokoro voice says nothing while its model downloads, so this
                // plays the sample once it's ready.
                Button {
                    model.previewVoice()
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .help("Play a sample")
                .accessibilityLabel("Play a sample")
            }
        case .failed:
            HStack {
                Text("Couldn't download")
                Button("Retry") {
                    model.voiceLoop.loadKokoroModel()
                }
            }
        }
    }
}
