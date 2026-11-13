@preconcurrency import AVFoundation

/// A short sound the voice loop plays so Adam can hear what happened without looking.
/// Each one is synthesized in code; there are no audio files.
public enum SoundCue: Sendable, CaseIterable {
    /// Listening has started, so Adam can talk: a few soft taps rising in pitch.
    case listeningStarted
    /// Listening has stopped: the same taps, falling in pitch.
    case listeningStopped
    /// The bot put a 👍 on a message: a soft two-note chime.
    case reaction
}

extension SoundCue {
    /// How long the cue lasts.
    var duration: Duration {
        .seconds(notes.map { $0.start + $0.length }.max() ?? 0)
    }

    /// The cue as one buffer in `format`: the pipeline's `speechFormat`, deinterleaved float.
    /// Every channel gets the same samples.
    func buffer(in format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let samples = samples(sampleRate: format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(format.channelCount) {
            channels[channel].update(from: samples, count: samples.count)
        }
        return buffer
    }

    /// The cue's mono samples at `sampleRate`. It starts and ends at silence, so it doesn't click.
    func samples(sampleRate: Double) -> [Float] {
        Note.render(notes, sampleRate: sampleRate)
    }

    private var notes: [Note] {
        switch self {
        case .listeningStarted: Self.taps(rising: true)
        case .listeningStopped: Self.taps(rising: false)
        case .reaction: Self.chime
        }
    }

    /// Three short taps on an A major chord (A5, C♯6, E6), 70 ms apart: 170 ms in all.
    private static func taps(rising: Bool) -> [Note] {
        let pitches = [880.0, 1108.73, 1318.51]
        return (rising ? pitches : pitches.reversed()).enumerated().map { index, pitch in
            Note(start: 0.07 * Double(index), length: 0.03, frequency: pitch, level: 0.2, decay: 0.008, overtone: 0.2)
        }
    }

    /// C6 then G6, each ringing out like a small bell: 410 ms in all.
    private static let chime = [
        Note(start: 0, length: 0.3, frequency: 1046.5, level: 0.15, decay: 0.09, overtone: 0.25),
        Note(start: 0.11, length: 0.3, frequency: 1567.98, level: 0.15, decay: 0.11, overtone: 0.25),
    ]
}

/// One note of a cue: a sine with a little of its octave, a fast attack and an exponential decay.
private struct Note {
    /// When it starts, in seconds from the start of the cue.
    var start: Double
    /// How long it lasts, in seconds. Its last few milliseconds fade to silence.
    var length: Double
    /// The pitch, in Hz.
    var frequency: Double
    /// The peak level, on a full scale of 1.
    var level: Float
    /// The decay's time constant, in seconds: the level falls to about a third in this time.
    var decay: Double
    /// The level of the octave above, relative to the pitch. It dies away twice as fast.
    var overtone: Double

    private static let attack = 0.002
    private static let release = 0.005

    /// Mixes `notes` into one buffer of samples, as long as the last of them to end.
    static func render(_ notes: [Note], sampleRate: Double) -> [Float] {
        let end = notes.map { $0.start + $0.length }.max() ?? 0
        var samples = [Float](repeating: 0, count: Int((end * sampleRate).rounded()))
        for note in notes {
            let first = Int((note.start * sampleRate).rounded())
            let count = min(Int((note.length * sampleRate).rounded()), samples.count - first)
            for index in 0..<max(count, 0) {
                samples[first + index] += note.sample(index, of: count, sampleRate: sampleRate)
            }
        }
        return samples
    }

    /// The note's `index`th sample of `count`. The first and the last are 0.
    private func sample(_ index: Int, of count: Int, sampleRate: Double) -> Float {
        let time = Double(index) / sampleRate
        let attack = min(1, time / Self.attack)
        let release = min(1, Double(count - 1 - index) / (Self.release * sampleRate))
        let decaying = exp(-max(0, time - Self.attack) / decay)
        let phase = 2 * Double.pi * frequency * time
        let tone = sin(phase) + overtone * decaying * sin(2 * phase)
        return level * Float(attack * release * decaying * tone)
    }
}
