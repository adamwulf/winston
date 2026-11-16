import SwiftUI
import VoiceLoop
import WinstonCore

/// Push-to-talk, opened by a long press on the mic button: one big button that listens while it
/// is held, with a line under it saying what is going on. The bottom bar puts voice mode in
/// push-to-talk while this shows (`AppModel.setPushToTalk(_:)`); `VoiceLoop` does the rest.
struct PushToTalkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// True from touch down to touch up, and back to false if the touch is cancelled.
    @GestureState private var isPressing = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            talkButton
            Text(status)
                .font(.title3)
                .foregroundStyle(statusIsPlaceholder ? .secondary : .primary)
                .multilineTextAlignment(.center)
                .lineLimit(4, reservesSpace: true)
                .padding(.horizontal)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            Button("Close") {
                dismiss()
            }
            .padding()
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 420)
        #endif
        .onChange(of: isPressing) { _, isPressing in
            if isPressing {
                model.voiceLoop.beginTalking()
            } else {
                model.voiceLoop.endTalking()
            }
        }
    }

    private var talkButton: some View {
        let isTalking = model.voiceLoop.isTalking
        return Circle()
            .fill(isTalking ? Color.red : Color.accentColor)
            .frame(width: 180, height: 180)
            .overlay {
                Image(systemName: isTalking ? "mic.fill" : "mic")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .scaleEffect(isTalking ? 1.12 : 1)
            .animation(.spring(duration: 0.2), value: isTalking)
            .opacity(canTalk ? 1 : 0.4)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0).updating($isPressing) { _, isPressing, _ in
                    isPressing = true
                },
                isEnabled: canTalk
            )
            .accessibilityElement()
            .accessibilityLabel("Talk")
            .accessibilityHint("Hold to talk, and let go to send.")
            .accessibilityAddTraits(.isButton)
    }

    /// Off while not starting means the loop gave up, such as after an interruption it can't
    /// resume from: holding would do nothing.
    private var canTalk: Bool {
        model.voiceLoop.state != .off || model.isStartingVoice
    }

    private var status: String {
        switch model.voiceLoop.state {
        case .off: model.isStartingVoice ? "Starting…" : "Not listening"
        case .listening(let partial) where !partial.isEmpty: partial
        case .listening: model.voiceLoop.isTalking ? "Listening…" : "Hold to talk"
        case .speaking: "Speaking…"
        }
    }

    private var statusIsPlaceholder: Bool {
        if case .listening(let partial) = model.voiceLoop.state { partial.isEmpty } else { true }
    }
}
