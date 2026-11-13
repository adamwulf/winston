import Foundation
import Synchronization

/// Decides, buffer by buffer, whether the microphone is hearing someone talk, from the
/// buffer's loudness (RMS) against a running estimate of the background noise.
///
/// The transcriber reports words in bursts that can lag the audio by more than a second, so
/// a pause in its results isn't a pause in speech. Loudness is immediate. Pure: tested
/// directly.
struct VoiceActivityDetector {
    /// Running estimate of the background noise level.
    private(set) var noiseFloor: Float?
    /// Loud buffers in a row so far.
    private var loudRun = 0

    /// Voice is anything this many times louder than the noise floor...
    static let ratio: Float = 3
    /// ...and above this absolute level (about -50 dBFS), so near-silence never counts...
    static let minimumLevel: Float = 0.003
    /// ...for at least this many buffers in a row (about 0.17 s at 4096 frames, 48 kHz), so a
    /// keyboard click doesn't count.
    static let minimumRun = 2

    /// Takes one buffer's RMS level and returns whether it sounds like speech.
    mutating func process(rms: Float) -> Bool {
        guard let floor = noiseFloor else {
            noiseFloor = rms
            return false
        }
        let isLoud = rms > floor * Self.ratio && rms > Self.minimumLevel
        loudRun = isLoud ? loudRun + 1 : 0
        // Falls quickly to quieter levels, and rises slowly, so speech doesn't raise the floor
        // much but a louder room is learned within several seconds.
        noiseFloor = rms < floor ? floor * 0.8 + rms * 0.2 : floor * 0.99 + rms * 0.01
        return loudRun >= Self.minimumRun
    }
}

/// The detector as the microphone tap uses it: written on the audio thread, read on the main
/// actor, which asks whether voice was heard since it last looked.
final class VoiceActivity: Sendable {
    private let detector = Mutex(VoiceActivityDetector())
    private let heardVoice = Atomic<Bool>(false)

    /// Runs on the audio thread for each microphone buffer.
    func process(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var sum: Float = 0
        for index in 0..<count {
            sum += samples[index] * samples[index]
        }
        let rms = (sum / Float(count)).squareRoot()
        if detector.withLock({ $0.process(rms: rms) }) {
            heardVoice.store(true, ordering: .relaxed)
        }
    }

    /// Whether voice was heard since the last call.
    func takeHeardVoice() -> Bool {
        heardVoice.exchange(false, ordering: .relaxed)
    }
}
