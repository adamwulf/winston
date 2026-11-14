#if os(iOS)
import PhotosUI
#endif
import SwiftUI
import UniformTypeIdentifiers
import VoiceLoop
import WinstonCore
import WinstonLogging

/// The bar under the messages: a text field with a + button for files and photos in text mode, or the
/// live transcript in voice mode, with the voice/text toggle to their left in both. (Double-tapping a
/// message toggles 👍 on it.)
struct BottomBar: View {
    private static let log = Logger(label: "app.attach")
    @Environment(AppModel.self) private var model
    @Binding var draft: String
    @State private var isPickingFile = false
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
                sendWithDraftAsCaption { caption in
                    await model.sendPhoto(caption: caption) {
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
            Button("Files", systemImage: "folder") { isPickingFile = true }
            Button("Photos", systemImage: "photo.on.rectangle") { isPickingPhoto = true }
        } label: {
            attachLabel
        }
        #else
        Button {
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
        switch result {
        case .success(let url):
            sendWithDraftAsCaption { caption in
                await model.sendDocument(caption: caption, fileURL: url)
            }
        case .failure(let error):
            // Codes only: a file error's description can name the file.
            Self.log.error("file picker failed", error.logCodes())
            model.errorMessage = userMessage(for: error)
        }
    }

    /// Sends an attachment with what's typed as its caption, and clears the text field once it's
    /// sent, unless Adam has typed something else meanwhile.
    private func sendWithDraftAsCaption(_ send: @escaping (String) async -> Bool) {
        let caption = draft
        Task {
            if await send(caption), draft == caption {
                draft = ""
            }
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
                    .symbolEffect(.variableColor.iterative, isActive: isListening)
            }
            .accessibilityLabel(model.voiceLoop.state == .speaking ? "Stop Speaking" : "Listening")

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

        Button("Discard") {
            model.voiceLoop.discardCurrentUtterance()
        }
        .disabled(!isListening)
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
        case .listening: "waveform"
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
        case .listening(let partial): partial.isEmpty ? "Listening…" : partial
        case .speaking: "Speaking…"
        }
    }

    private var transcriptIsPlaceholder: Bool {
        if case .listening(let partial) = model.voiceLoop.state { partial.isEmpty } else { true }
    }

    // MARK: - Both modes

    private var modeToggle: some View {
        Button(
            model.isVoiceMode ? "Text Mode" : "Voice Mode",
            systemImage: model.isVoiceMode ? "keyboard" : "mic"
        ) {
            Task { await model.setVoiceMode(!model.isVoiceMode) }
        }
        .labelStyle(.iconOnly)
    }
}
