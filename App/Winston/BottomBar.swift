import PhotosUI
import SwiftUI
import VoiceLoop
import WinstonCore

/// The bar under the messages: a text field and photo button in text mode, or the live transcript in
/// voice mode, plus the 👍 button and the voice/text toggle in both.
struct BottomBar: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: String
    @State private var photoItem: PhotosPickerItem?

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
                if model.isVoiceMode {
                    voiceControls
                } else {
                    textControls
                }
                thumbsUpButton
                modeToggle
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
        // PhotosPicker's label closure is Sendable, so it can't read the main-actor model.
        let isSendingPhoto = model.isSendingPhoto
        PhotosPicker(selection: $photoItem, matching: .images) {
            if isSendingPhoto {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "photo")
            }
        }
        .accessibilityLabel("Send Photo")
        .disabled(model.isSendingPhoto)
        .onChange(of: photoItem) {
            guard let item = photoItem else { return }
            photoItem = nil
            let caption = draft
            Task {
                let sent = await model.sendPhoto(caption: caption) {
                    try await item.loadTransferable(type: Data.self)
                }
                if sent, draft == caption {
                    draft = ""
                }
            }
        }

        TextField("Message", text: $draft, axis: .vertical)
            .lineLimit(1...5)
            .textFieldStyle(.roundedBorder)
            .onSubmit(send)

        Button("Send", systemImage: "arrow.up.circle.fill", action: send)
            .labelStyle(.iconOnly)
            .disabled(!canSend)
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

    private var thumbsUpButton: some View {
        let message = model.latestIncomingMessage
        let isChosen = message?.hasMyThumbsUp ?? false
        return Button("👍 Latest Message", systemImage: isChosen ? "hand.thumbsup.fill" : "hand.thumbsup") {
            guard let message else { return }
            Task { await model.toggleThumbsUp(on: message) }
        }
        .labelStyle(.iconOnly)
        .disabled(message == nil)
    }

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
