#if os(iOS)
import PhotosUI
#endif
import SwiftUI
import UniformTypeIdentifiers
import VoiceLoop
import WinstonCore
import WinstonLogging

/// The bar under the messages: a text field with a + button for files and photos in text mode, or the
/// live transcript with a mute button in voice mode, with the voice/text toggle to their left in both.
/// A long press on the toggle in text mode opens push-to-talk. (Double-tapping a message toggles 👍 on it.)
struct BottomBar: View {
    private static let log = Logger(label: "app.attach")
    @Environment(AppModel.self) private var model
    @Environment(Presentations.self) private var presentations
    @Binding var draft: String
    @State private var isPickingFile = false
    @State private var pickerNotificationCount = 0
    @State private var isShowingPushToTalk = false
    #if os(iOS)
    @State private var isPickingPhoto = false
    @State private var photoItem: PhotosPickerItem?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Always takes its space, so the bar (and the message list above it) doesn't jump
            // each time the bot starts or stops typing.
            Text("typing…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .opacity(model.isBotTyping ? 1 : 0)
                .accessibilityHidden(!model.isBotTyping)
            HStack(spacing: 12) {
                // On the left, so Send is the only button to the right of the text field.
                modeToggle
                if model.isVoiceMode {
                    voiceControls
                } else {
                    textControls
                }
            }
            .imageScale(.large)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .onChange(of: model.notificationOpenCount) {
            closePickers()
            isShowingPushToTalk = false
        }
        // A file Adam opened, so its agent sheet can show. Not push-to-talk, which could be in a
        // hold: the agent sheet waits for it to close.
        .onChange(of: model.openedFileCount) {
            closePickers()
        }
        // Closing it, however it closes, leaves push-to-talk for text mode.
        .sheet(isPresented: $isShowingPushToTalk, onDismiss: leavePushToTalk) {
            PushToTalkSheet()
        }
        // Voice mode ended under it, such as a failed start, whose error then shows.
        .onChange(of: model.isVoiceMode) {
            if !model.isVoiceMode {
                isShowingPushToTalk = false
            }
        }
        // For the agent sheet, which waits while any of these shows.
        .onChange(of: isPicking, initial: true) {
            presentations.isShowingPicker = isPicking
        }
        .onChange(of: isShowingPushToTalk, initial: true) {
            presentations.isShowingPushToTalk = isShowingPushToTalk
        }
        .onDisappear {
            presentations.isShowingPicker = false
            presentations.isShowingPushToTalk = false
        }
    }

    /// Closes the file and photo pickers, for a notification tap or a file opened in Winston.
    private func closePickers() {
        isPickingFile = false
        #if os(iOS)
        isPickingPhoto = false
        photoItem = nil
        #endif
    }

    /// Whether the file or photo picker is showing.
    private var isPicking: Bool {
        #if os(iOS)
        isPickingFile || isPickingPhoto
        #else
        isPickingFile
        #endif
    }

    // MARK: - Text mode

    @ViewBuilder
    private var textControls: some View {
        attachButton
            .accessibilityLabel("Attach")
            .disabled(model.isSendingAttachment)
            // Any file, but not a folder.
            .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.data], onCompletion: sendFile)
            #if os(iOS)
            .photosPicker(isPresented: $isPickingPhoto, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) {
                guard let item = photoItem else { return }
                photoItem = nil
                let notificationCount = pickerNotificationCount
                guard notificationCount == model.notificationOpenCount else { return }
                $draft.sendAsCaption { caption in
                    // A notification can arrive after selection but before this task starts.
                    guard notificationCount == model.notificationOpenCount else { return false }
                    return await model.sendPhoto(caption: caption) {
                        try await item.loadTransferable(type: Data.self)
                    }
                }
            }
            #endif

        TextField("Message", text: $draft, axis: .vertical)
            .lineLimit(1...5)
            .textFieldStyle(.roundedBorder)
            .onSubmit(send)

        Button("Send", systemImage: "arrow.up.circle.fill", action: send)
            .labelStyle(.iconOnly)
            .disabled(!canSend)
    }

    /// The + button. The Mac opens the file picker straight away; iOS offers Files or Photos.
    @ViewBuilder
    private var attachButton: some View {
        #if os(iOS)
        Menu {
            Button("Files", systemImage: "folder") {
                pickerNotificationCount = model.notificationOpenCount
                isPickingFile = true
            }
            Button("Photos", systemImage: "photo.on.rectangle") {
                pickerNotificationCount = model.notificationOpenCount
                isPickingPhoto = true
            }
        } label: {
            attachLabel
        }
        #else
        Button {
            pickerNotificationCount = model.notificationOpenCount
            isPickingFile = true
        } label: {
            attachLabel
        }
        #endif
    }

    @ViewBuilder
    private var attachLabel: some View {
        if model.isSendingAttachment {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: "plus")
        }
    }

    private func sendFile(_ result: Result<URL, any Error>) {
        let notificationCount = pickerNotificationCount
        guard notificationCount == model.notificationOpenCount else { return }
        switch result {
        case .success(let url):
            $draft.sendAsCaption { caption in
                guard notificationCount == model.notificationOpenCount else { return false }
                return await model.sendDocuments(caption: caption, fileURLs: [url])
            }
        case .failure(let error):
            // Codes only: a file error's description can name the file.
            Self.log.error("file picker failed", error.logCodes())
            model.errorMessage = userMessage(for: error)
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sends the text exactly as typed, so slash commands work. Puts it back if sending fails.
    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        Task {
            let sent = await model.sendText(text)
            if !sent, draft.isEmpty {
                draft = text
            }
        }
    }

    // MARK: - Voice mode

    @ViewBuilder
    private var voiceControls: some View {
        if model.voiceLoop.state == .off && !model.isStartingVoice {
            // Off while not starting means VoiceLoop gave up, such as after an interruption it can't resume from.
            twoLineArea {
                Button("Resume Listening", systemImage: "mic.slash") {
                    Task { await model.setVoiceMode(true) }
                }
            }
        } else {
            Button(action: tapIndicator) {
                Image(systemName: indicatorSymbol)
                    .symbolEffect(.variableColor.iterative, isActive: isListening && !model.voiceLoop.isInputMuted)
            }
            .accessibilityLabel(
                model.voiceLoop.state == .speaking ? "Stop Speaking" : model.voiceLoop.isInputMuted ? "Muted" : "Listening"
            )

            // Longer transcripts scroll, kept at the newest words; a short one sits on the
            // first line.
            twoLineArea {
                ScrollView {
                    Text(transcript)
                        .foregroundStyle(transcriptIsPlaceholder ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.topLeading, for: .alignment)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
            }
        }

        muteButton
    }

    /// Mutes or unmutes the microphone, as a press of the AirPods stem does. The symbol shows
    /// whether it is on, red while muted, and the label says what a tap does.
    private var muteButton: some View {
        let isMuted = model.voiceLoop.isInputMuted
        return Button(isMuted ? "Unmute" : "Mute", systemImage: isMuted ? "mic.slash" : "mic") {
            model.voiceLoop.toggleInputMute()
        }
        .labelStyle(.iconOnly)
        .contentTransition(.symbolEffect(.replace))
        #if os(macOS)
        // A Mac push button ignores the tint.
        .foregroundStyle(isMuted ? Color.red : Color.primary)
        #else
        .tint(isMuted ? .red : nil)
        #endif
        // Not until listening has started, so the mute is never set before the audio session.
        .disabled(model.voiceLoop.state == .off)
    }

    /// A space exactly two text lines tall and as wide as it can be, holding `content` at its
    /// leading edge. Every voice-mode state uses it, so the bar (and the message list above
    /// it) keeps one height.
    private func twoLineArea(@ViewBuilder _ content: () -> some View) -> some View {
        Text("\n")
            .lineLimit(2, reservesSpace: true)
            .hidden()
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                content()
            }
    }

    private var isListening: Bool {
        if case .listening = model.voiceLoop.state { true } else { false }
    }

    private var indicatorSymbol: String {
        switch model.voiceLoop.state {
        case .off: "mic.slash"
        // Muted from the AirPods or the mute button.
        case .listening: model.voiceLoop.isInputMuted ? "mic.slash" : "waveform"
        case .speaking: "speaker.wave.2.fill"
        }
    }

    private func tapIndicator() {
        if model.voiceLoop.state == .speaking {
            model.voiceLoop.stopSpeaking()
        }
    }

    private var transcript: String {
        switch model.voiceLoop.state {
        case .off: "Starting…"
        case .listening(let partial): partial.isEmpty ? (model.voiceLoop.isInputMuted ? "Muted" : "Listening…") : partial
        case .speaking: "Speaking…"
        }
    }

    private var transcriptIsPlaceholder: Bool {
        if case .listening(let partial) = model.voiceLoop.state { partial.isEmpty } else { true }
    }

    // MARK: - Both modes

    /// A tap switches modes. In text mode, a long press opens push-to-talk instead.
    private var modeToggle: some View {
        Button(
            model.isVoiceMode ? "Text Mode" : "Voice Mode",
            systemImage: model.isVoiceMode ? "keyboard" : "mic"
        ) {
            // The touch up that ends a long press would switch modes too.
            guard !isShowingPushToTalk else { return }
            Task { await model.setVoiceMode(!model.isVoiceMode) }
        }
        .labelStyle(.iconOnly)
        .simultaneousGesture(
            LongPressGesture().onEnded { _ in openPushToTalk() },
            isEnabled: !model.isVoiceMode
        )
        .accessibilityActions {
            if !model.isVoiceMode {
                Button("Push to Talk", action: openPushToTalk)
            }
        }
    }

    private func openPushToTalk() {
        guard !model.isVoiceMode, !isShowingPushToTalk else { return }
        isShowingPushToTalk = true
        Task { await model.setPushToTalk(true) }
    }

    private func leavePushToTalk() {
        Task { await model.setPushToTalk(false) }
    }
}

extension Binding<String> {
    /// Sends an attachment with this draft as its caption, and clears the draft once `send` says the
    /// caption was sent, unless Adam has typed something else meanwhile. Used by the + button and by
    /// files dropped on the chat.
    func sendAsCaption(_ send: @escaping (String) async -> Bool) {
        let caption = wrappedValue
        Task {
            if await send(caption), wrappedValue == caption {
                wrappedValue = ""
            }
        }
    }
}
