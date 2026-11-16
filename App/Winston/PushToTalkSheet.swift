import SwiftUI
import VoiceLoop
import WinstonCore

/// Push-to-talk, opened by a long press on the mic button: one big button that listens while
/// it is held, with a line under it saying what is going on. A hold anywhere below a strip at
/// the top holds the button; the strip keeps Close and room to pull the sheet down. The bottom
/// bar puts voice mode in push-to-talk while this shows (`AppModel.setPushToTalk(_:)`);
/// `VoiceLoop` does the rest.
struct PushToTalkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// True from touch down to touch up, and back to false if the touch is cancelled.
    @GestureState private var isPressing = false

    /// The strip at the top that a hold doesn't cover, so a drag there still pulls the sheet
    /// down instead of talking.
    private static let pullDownStripHeight: CGFloat = 72

    var body: some View {
        VStack(spacing: 0) {
            Button("Close") {
                dismiss()
            }
            .padding()
            .frame(maxWidth: .infinity, minHeight: Self.pullDownStripHeight, alignment: .topTrailing)
            holdArea
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

    /// Everything below the strip at the top: a hold anywhere in it holds the button.
    private var holdArea: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0).updating($isPressing) { _, isPressing, _ in
                isPressing = true
            },
            isEnabled: canTalk
        )
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
            .accessibilityElement()
            .accessibilityLabel("Talk")
            .accessibilityValue(isTalking ? "Listening" : canTalk ? "" : notReadyStatus)
            .accessibilityHint(
                isTalking ? "Activate to stop talking and send." : canTalk ? "Activate to start talking." : ""
            )
            .accessibilityAddTraits(.isButton)
            // VoiceOver can't hold: one activation starts talking, the next ends it.
            .accessibilityAction {
                if model.voiceLoop.isTalking {
                    model.voiceLoop.endTalking()
                } else {
                    model.voiceLoop.beginTalking()
                }
            }
            // Like the hold, VoiceOver's action waits until the loop can talk, and says so.
            .disabled(!canTalk)
    }

    /// Until the loop is listening a press would do nothing. A hold already under way stays
    /// enabled, so the loop rebuilding its engine doesn't end it.
    private var canTalk: Bool {
        model.voiceLoop.canTalk || model.voiceLoop.isTalking
    }

    private var status: String {
        let loop = model.voiceLoop
        switch loop.state {
        case .listening(let partial) where !partial.isEmpty: return partial
        case .speaking: return "Speaking…"
        default: break
        }
        if loop.isTalking { return "Listening…" }
        if loop.canTalk { return "Hold to talk" }
        return notReadyStatus
    }

    /// Why the button can't be held yet. Off while not starting means the loop gave up, such as
    /// after an interruption it can't resume from.
    private var notReadyStatus: String {
        model.voiceLoop.state == .off && !model.isStartingVoice ? "Not listening" : "Starting…"
    }

    private var statusIsPlaceholder: Bool {
        if case .listening(let partial) = model.voiceLoop.state { partial.isEmpty } else { true }
    }
}
