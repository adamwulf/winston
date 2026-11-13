@preconcurrency import AVFoundation
import Logging
import LogSupport

/// Plays speech while the voice loop is off, for voice previews in settings. Each preview gets
/// an engine of its own that plays straight to the speaker, through the same pitch shift as
/// replies. On iOS it uses a playback session, so the silent switch doesn't mute it, and other
/// apps' audio is turned down while it plays.
///
/// To play a preview, call `play(pitch:)` and feed the playback it returns: `receive(_:)` with
/// each buffer, then `synthesisFinished()` after the last. Any source of buffers works, such
/// as `AVSpeechSynthesizer.write(_:toBufferCallback:)`. A new preview cuts off the one before,
/// and the engine stops once a preview has played. If the engine stops on its own (the audio
/// hardware changed, say AirPods connected) or, on iOS, a call or Siri interrupts the audio
/// session, the preview ends there.
@MainActor
final class PreviewPlayer {
    private static let log = Logger(label: "voice.preview")

    private struct Preview {
        let engine: AVAudioEngine
        let output: SpeechOutput
        let playback: SpeechPlayback
        /// End the preview if the engine stops on its own or the session is interrupted.
        let watchers: [Task<Void, Never>]
    }

    private let environment: VoiceEnvironment
    private var current: Preview?

    init(environment: VoiceEnvironment) {
        self.environment = environment
    }

    /// Starts a preview at `pitch` times the voice's own pitch (a `VoiceLoop.speechPitch`),
    /// cutting off the one playing, and returns the playback to feed its audio into. Throws
    /// when the engine or, on iOS, the audio session can't start.
    func play(pitch: Float) throws -> SpeechPlayback {
        stop()
        let engine = try environment.makeEngine()
        let output = try SpeechOutput(engine: engine)
        output.connect()
        output.setPitch(pitch)
        // A preview is never queued again, so it needs no text.
        let playback = output.makePlayback(text: "") { [weak self] playback in
            Task { @MainActor in self?.finished(playback) }
        }
        // Watching from before the start, so a change while starting isn't missed.
        let configurationChanges = NotificationCenter.default.notifications(
            named: .AVAudioEngineConfigurationChange,
            object: engine
        )
        #if os(iOS)
        let interruptions = NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification)
            .map { InterruptionEvent($0) }
        #endif
        do {
            try Self.activateAudioSession()
            engine.prepare()
            try engine.start()
        } catch {
            engine.stop()
            VoiceLoop.deactivateAudioSession()
            throw error
        }
        output.player.play()
        let engineWatcher = Task { [weak self, weak engine] in
            for await _ in configurationChanges {
                guard let self, let engine else { return }
                if !engine.isRunning {
                    self.endEarly(playback, reason: "configurationChange")
                    return
                }
            }
        }
        #if os(iOS)
        let interruptionWatcher = Task { [weak self] in
            for await event in interruptions {
                guard let self else { return }
                if case .began = event {
                    self.endEarly(playback, reason: "interruption")
                    return
                }
            }
        }
        let watchers = [engineWatcher, interruptionWatcher]
        #else
        let watchers = [engineWatcher]
        #endif
        current = Preview(engine: engine, output: output, playback: playback, watchers: watchers)
        return playback
    }

    /// Stops the preview playing, if there is one.
    func stop() {
        guard let current else { return }
        self.current = nil
        for watcher in current.watchers { watcher.cancel() }
        current.playback.cancel()
        current.output.player.stop()
        current.engine.stop()
        VoiceLoop.deactivateAudioSession()
    }

    private func finished(_ playback: SpeechPlayback) {
        // A preview that was cut off reports finishing too, when its player stops.
        guard current?.playback === playback else { return }
        stop()
    }

    /// The engine stopped itself because the audio hardware changed, or a call or Siri took
    /// the audio session. Either way the preview may never report finishing. A preview is
    /// short, so it ends rather than starting again, and other audio comes back up. `reason`
    /// says which, for the logs.
    private func endEarly(_ playback: SpeechPlayback, reason: String) {
        guard current?.playback === playback else { return }
        Self.log.notice("voice preview ended early", ["reason": reason])
        stop()
    }

    /// On iOS, a playback session: the silent switch doesn't mute it, and other apps' audio is
    /// turned down rather than stopped. Voice mode sets up its own session when it starts.
    private static func activateAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
        #endif
    }
}
