@preconcurrency import AVFoundation
import Logging

/// Plays speech while the voice loop is off, for voice previews in settings. Each preview gets
/// an engine of its own that plays straight to the speaker, through the same pitch shift as
/// replies. On iOS it uses a playback session, so the silent switch doesn't mute it, and other
/// apps' audio is turned down while it plays.
///
/// To play a preview, call `play(pitch:)` and feed the playback it returns: `receive(_:)` with
/// each buffer, then `synthesisFinished()` after the last. Any source of buffers works, such
/// as `AVSpeechSynthesizer.write(_:toBufferCallback:)`. A new preview cuts off the one before,
/// and the engine stops once a preview has played. If the engine stops on its own (the audio
/// hardware changed, say AirPods connected), the preview ends there.
@MainActor
final class PreviewPlayer {
    private static let log = Logger(label: "voice.preview")

    private struct Preview {
        let engine: AVAudioEngine
        let output: SpeechOutput
        let playback: SpeechPlayback
        /// Ends the preview if the engine stops on its own.
        let watcher: Task<Void, Never>
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
        let watcher = Task { [weak self, weak engine] in
            for await _ in configurationChanges {
                guard let self, let engine else { return }
                if !engine.isRunning {
                    self.engineStopped(playback)
                    return
                }
            }
        }
        current = Preview(engine: engine, output: output, playback: playback, watcher: watcher)
        return playback
    }

    /// Stops the preview playing, if there is one.
    func stop() {
        guard let current else { return }
        self.current = nil
        current.watcher.cancel()
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

    /// The engine stopped itself because the audio hardware changed. A preview is short, so
    /// it ends rather than starting again, and other audio comes back up.
    private func engineStopped(_ playback: SpeechPlayback) {
        guard current?.playback === playback else { return }
        Self.log.notice("voice preview stopped by an audio configuration change")
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
