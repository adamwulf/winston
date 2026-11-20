import SwiftUI
import VoiceLoop
import WinstonCore
import WinstonLogging

/// The pause threshold, the voice with its speed and pitch, the Kokoro voices' model and its status, pronunciations, whether other audio pauses, debug logs, Log out, and deleting the downloaded voice models. AppModel persists the settings and applies them to the
/// voice loop. A sheet on iOS, where the pronunciations are a screen of their own; the standard Settings window, in tabs, on macOS.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingLogOut = false
    @State private var confirmingModelDeletion = false
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
            Form {
                voiceModeSection
                kokoroSection
                pronunciationsLink
                otherAudioSection
                debugLogsSection
                NotificationSettings()
                logOutSection
                modelDeletionSection
            }
            .formStyle(.grouped)
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
        // The standard Settings tabs: all in one form, the window grew taller than the screen.
        TabView {
            Tab("Voice", systemImage: "waveform") {
                pane {
                    voiceModeSection
                    kokoroSection
                    otherAudioSection
                }
            }
            Tab("Pronunciations", systemImage: "character.bubble") {
                // As tall as its list up to a limit, so a long list scrolls rather than growing the window.
                Form {
                    PronunciationsSection()
                }
                .formStyle(.grouped)
                .frame(width: Self.paneWidth)
                .frame(maxHeight: 400)
                .fixedSize(horizontal: false, vertical: true)
            }
            Tab("Advanced", systemImage: "gearshape.2") {
                pane {
                    debugLogsSection
                    logOutSection
                    modelDeletionSection
                }
            }
        }
        #endif
    }

    #if os(macOS)
    private static let paneWidth: CGFloat = 460

    /// A tab's form, as tall as its content: the window resizes to fit each tab.
    private func pane(@ViewBuilder content: () -> some View) -> some View {
        Form(content: content)
            .formStyle(.grouped)
            .frame(width: Self.paneWidth)
            .fixedSize(horizontal: false, vertical: true)
    }
    #endif

    @ViewBuilder
    private var voiceModeSection: some View {
        @Bindable var model = model
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
    }

    @ViewBuilder
    private var kokoroSection: some View {
        @Bindable var model = model
        if voices.contains(where: { $0.engine == .kokoro }) {
            Section {
                Picker("Voice model", selection: $model.kokoroModelVariant) {
                    Text("No Model").tag(KokoroModelVariant?.none)
                    ForEach(KokoroModelVariant.allCases, id: \.self) { variant in
                        Text(variant.name).tag(Optional(variant))
                    }
                }
                // With no model there is nothing to download or load.
                if let variant = model.kokoroModelVariant {
                    LabeledContent("Status") {
                        kokoroModelStatus(of: variant)
                    }
                    // Its own row, full width under the status, like the sliders under theirs.
                    if case .downloading(let progress) = model.voiceLoop.kokoroModelState, progress < 1 {
                        ProgressView(value: progress) {
                            Text("Download progress")
                        }
                        .labelsHidden()
                    }
                    // Core ML reports no progress while it builds the model, so this says why it waits.
                    if model.voiceLoop.kokoroLoadStage?.stage == .coreML {
                        Text("A model's first load can take several minutes. Later loads are quick.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Kokoro Voices")
            } footer: {
                Text("Kokoro voices are neural voices that run on this device. Each voice model downloads the first time a Kokoro voice uses it, and until it's ready, the best system voice speaks. With No Model, no download starts and the best system voice speaks. A longer model cuts fewer sentences into pieces, but takes longer to start speaking. FluidAudio models speak only at normal speed. The models are removed after a day without a Kokoro voice.")
            }
        }
    }

    #if os(iOS)
    /// A row that pushes the pronunciations, so a long list doesn't make Settings long.
    private var pronunciationsLink: some View {
        Section {
            NavigationLink("Pronunciations") {
                Form {
                    PronunciationsSection()
                }
                .formStyle(.grouped)
                .navigationTitle("Pronunciations")
            }
        }
    }
    #endif

    @ViewBuilder
    private var otherAudioSection: some View {
        @Bindable var model = model
        Section {
            Toggle("Pause Other Audio", isOn: $model.pausesOtherAudio)
        } footer: {
            Text("Turn this off to keep music and other audio playing during voice mode.")
        }
    }

    private var debugLogsSection: some View {
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
    }

    /// On the Mac the Settings window opens before login too; only offer Log Out once logged in.
    @ViewBuilder
    private var logOutSection: some View {
        if model.authState == .ready {
            Section {
                Button("Log Out", role: .destructive) {
                    confirmingLogOut = true
                }
                .confirmationDialog("Log out of Telegram?", isPresented: $confirmingLogOut) {
                    Button("Log Out", role: .destructive) {
                        dismiss()
                        Task { await model.logOut() }
                    }
                }
            }
        }
    }

    private var modelDeletionSection: some View {
        Section {
            Button("Delete Downloaded Voice Models", role: .destructive) {
                confirmingModelDeletion = true
            }
            .disabled(isKokoroModelLoading)
            .confirmationDialog("Delete downloaded voice models?", isPresented: $confirmingModelDeletion) {
                Button("Delete", role: .destructive) {
                    model.deleteKokoroModels()
                }
            }
        } footer: {
            Text("Deletes every Kokoro model stored on this device and sets the voice model to No Model, so nothing downloads until you choose a model again. Unavailable while a model downloads or loads.")
        }
    }

    /// Whether the Kokoro model is downloading or loading.
    private var isKokoroModelLoading: Bool {
        switch model.voiceLoop.kokoroModelState {
        case .loading, .downloading: true
        case .notLoaded, .ready, .failed: false
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
        let suffix = switch (voice.engine, voice.quality) {
        case (.kokoro, _): " (Kokoro)"
        case (.system, .premium): " (Premium)"
        case (.system, .enhanced): " (Enhanced)"
        case (.system, .standard): ""
        }
        // Some system voices already have it in their name, such as "Susan (Enhanced)" on iOS.
        return voice.name.hasSuffix(suffix) ? voice.name : voice.name + suffix
    }

    /// Where the chosen Kokoro model, `variant`, is: its size before anything has asked for it,
    /// the download's percentage (its progress bar is a row of its own), the load's stage, ready
    /// with a button that plays a sample, or failed with a retry.
    @ViewBuilder
    private func kokoroModelStatus(of variant: KokoroModelVariant) -> some View {
        switch model.voiceLoop.kokoroModelState {
        case .notLoaded:
            Text("About \(variant.downloadMegabytes) MB")
        case .loading, .downloading(progress: 1...):
            HStack {
                ProgressView()
                    .controlSize(.small)
                kokoroLoadStatus
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

    /// Once the load is past the download, its stage and the time spent in it, such as "Building
    /// model… 2:41", counting each second. "Loading…" until then.
    @ViewBuilder
    private var kokoroLoadStatus: some View {
        if let loadStage = model.voiceLoop.kokoroLoadStage, let name = Self.name(of: loadStage.stage) {
            TimelineView(.periodic(from: loadStage.since, by: 1)) { context in
                let elapsed = Duration.seconds(max(0, context.date.timeIntervalSince(loadStage.since)))
                Text("\(name) \(elapsed.formatted(.time(pattern: .minuteSecond)))")
                    .monospacedDigit()
            }
        } else {
            Text("Loading…")
        }
    }

    /// `stage` as the status names it, or nil for the download, which has a status of its own.
    private static func name(of stage: KokoroLoadStage) -> String? {
        switch stage {
        case .downloading: nil
        case .vocabulary, .g2p, .voices: "Preparing…"
        case .coreML: "Building model…"
        case .warmingUp: "Warming up…"
        }
    }
}

/// The pronunciations, a row each, and a button that adds one: on iOS, the screen Settings
/// pushes from its Pronunciations row; on the Mac, the Pronunciations tab.
private struct PronunciationsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            ForEach($model.pronunciations) { $pronunciation in
                PronunciationRow(pronunciation: $pronunciation) { text in
                    model.previewPronunciation(text)
                } playPhonemes: { word, phonemes in
                    model.previewPronunciation(word: word, phonemes: phonemes)
                } remove: {
                    // Read through the binding first: reading it while removeAll changes
                    // the array it reads from is an exclusive access conflict.
                    let id = pronunciation.id
                    model.pronunciations.removeAll { $0.id == id }
                }
            }
            .onDelete { offsets in
                model.pronunciations.remove(atOffsets: offsets)
            }
            Button("Add Pronunciation") {
                model.pronunciations.append(Pronunciation())
            }
        } header: {
            Text("Pronunciations")
        } footer: {
            Text("Say As: each word is said the way you write it beside it, by every voice. Words match only with the same case, such as JSON said as Jason. IPA: Kokoro voices say the word with the phonemes you write, in Kokoro's symbols, such as kˈOkəɹO for Kokoro; symbols Kokoro doesn't know are dropped. Other voices say the word as written.")
        }
    }
}

/// One pronunciation: the word, whether it is said as other text (Say As) or with Kokoro phonemes
/// (IPA), and that text or those phonemes. Word and text are typed exactly as written, since the
/// word matches only with the same case. Each side has a play button in the chosen voice: the
/// word's says it as written, so it can be compared with the other side's, which says the text as
/// written, or the word with the phonemes (with a system voice, the word as written, as a reply
/// would). On the Mac a row is one line, with a remove button; on iOS it is two, the word over the
/// replacement, and is removed by swiping it.
private struct PronunciationRow: View {
    @Binding var pronunciation: Pronunciation
    /// Says the text it's given: the word, or a Say As replacement.
    let play: (String) -> Void
    /// Says a word with phonemes: an IPA replacement.
    let playPhonemes: (_ word: String, _ phonemes: String) -> Void
    let remove: () -> Void

    var body: some View {
        rowLayout {
            HStack {
                TextField("Word", text: $pronunciation.word, prompt: Text("Word"))
                PlayButton(help: "Play Word", accessibilityLabel: "Play word", isEnabled: !isBlank(pronunciation.word)) {
                    play(pronunciation.word)
                }
                Picker("Pronunciation Type", selection: $pronunciation.mode) {
                    Text("Say As").tag(Pronunciation.Mode.respelling)
                    Text("IPA").tag(Pronunciation.Mode.phonetic)
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("Say As or IPA")
            }
            HStack {
                replacementSide
                #if os(macOS)
                Button(action: remove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove")
                .accessibilityLabel("Remove pronunciation")
                #endif
            }
        }
        .labelsHidden()
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
    }

    /// One line on the Mac; on iOS, the word over the replacement, so each field has room.
    private var rowLayout: AnyLayout {
        #if os(iOS)
        AnyLayout(VStackLayout(alignment: .leading))
        #else
        AnyLayout(HStackLayout())
        #endif
    }

    /// The replacement field and what plays it, for the mode chosen. Controls for one mode only
    /// go in its case.
    @ViewBuilder private var replacementSide: some View {
        let prompt: LocalizedStringKey = pronunciation.mode == .phonetic ? "IPA" : "Say as"
        TextField(prompt, text: $pronunciation.replacement, prompt: Text(prompt))
        switch pronunciation.mode {
        case .respelling:
            PlayButton(help: "Play Say As", accessibilityLabel: "Play replacement", isEnabled: !isBlank(pronunciation.replacement)) {
                play(pronunciation.replacement)
            }
        case .phonetic:
            PlayButton(
                help: "Play IPA",
                accessibilityLabel: "Play phonemes",
                isEnabled: !isBlank(pronunciation.word) && !isBlank(pronunciation.replacement)
            ) {
                playPhonemes(pronunciation.word, pronunciation.replacement)
            }
        }
    }

    private func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A pronunciation row's button for playing one of its sides, disabled while there's nothing to
/// play.
private struct PlayButton: View {
    let help: LocalizedStringKey
    let accessibilityLabel: LocalizedStringKey
    let isEnabled: Bool
    let play: () -> Void

    var body: some View {
        // Borderless, so on iOS only the button plays, not a tap anywhere in the row.
        Button {
            play()
        } label: {
            Image(systemName: "play.circle")
                #if os(iOS)
                // Borderless, only the symbol itself would take a tap: too small a target.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                #endif
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }
}
