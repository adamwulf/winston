@preconcurrency import AVFoundation

/// Where speech plays in an engine: a player node, then a pitch shift, into the main mixer.
/// The voice loop's pipeline has one, and so does the preview player.
///
/// The pitch is shifted here rather than with `AVSpeechUtterance.pitchMultiplier`, which some
/// voices ignore (the Siri voices do), so every voice is shifted the same way.
@MainActor
final class SpeechOutput {
    let player = AVAudioPlayerNode()
    /// Moves speech up or down without changing its speed. Bypassed at normal pitch, so the
    /// voice then plays exactly as the synthesizer made it.
    let pitchShift = AVAudioUnitTimePitch()
    /// The player's connection format; speech buffers are converted to it.
    let format: AVAudioFormat
    /// When a spoken buffer counts as played. `.dataPlayedBack` waits until the sound has left
    /// the speaker, but it only fires for an engine that renders to an audio device. An engine
    /// rendering offline, as in the tests, is done with a buffer once it is rendered. Offline,
    /// the pitch shift (even bypassed) pulls the player a render pass ahead, so that can be one
    /// pass before the buffer's sound reaches the output.
    let completion: AVAudioPlayerNodeCompletionCallbackType
    private let engine: AVAudioEngine

    /// A player and pitch shift for `engine`, which `connect()` adds to it.
    init(engine: AVAudioEngine) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            throw AudioFormatError()
        }
        self.engine = engine
        self.format = format
        completion = engine.isInManualRenderingMode ? .dataRendered : .dataPlayedBack
        pitchShift.bypass = true
    }

    /// Attaches the player and the pitch shift to the engine and connects them to its main
    /// mixer. Call it once, before the engine starts.
    func connect() {
        engine.attach(player)
        engine.attach(pitchShift)
        // Mono into the mixer, which spreads it to every output channel.
        engine.connect(player, to: pitchShift, format: format)
        engine.connect(pitchShift, to: engine.mainMixerNode, format: format)
    }

    /// Plays the next message at `multiplier` times the voice's own pitch, as
    /// `VoiceLoop.speechPitch`: 1 is normal. Call it before `makePlayback(text:onFinished:)`.
    func setPitch(_ multiplier: Float) {
        let range = VoiceLoop.speechPitches
        let cents = 1200 * log2(min(max(multiplier, range.lowerBound), range.upperBound))
        pitchShift.pitch = cents
        // A shift under a cent can't be heard; bypassing it also allows for slider rounding.
        pitchShift.bypass = abs(cents) < 1
    }

    /// A playback for one message on this player, at the pitch set last. `onFinished` is
    /// called, on an arbitrary thread, once the message has played.
    func makePlayback(text: String, onFinished: @escaping @Sendable (SpeechPlayback) -> Void) -> SpeechPlayback {
        SpeechPlayback(
            text: text,
            player: player,
            format: format,
            completion: completion,
            trailingSilence: pitchShift.bypass ? 0 : AVAudioFrameCount(format.sampleRate * Self.pitchShiftTail),
            onFinished: onFinished
        )
    }

    /// How long a shifted message keeps sounding after its last buffer, in seconds, with a
    /// margin. The pitch shift works on overlapping windows, so its output runs on after its
    /// input ends: on a Mac, the last shifted sound left it up to 45 ms after the player's
    /// `.dataPlayedBack` completion for that buffer. A message that is shifted ends with this
    /// much silence, and finishes when the silence has played.
    static let pitchShiftTail = 0.1
}
