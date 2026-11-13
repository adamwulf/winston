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
    /// One buffer's loudness and what the detector made of it, for the timeline log.
    struct Reading: Sendable {
        /// The buffer's RMS level.
        let level: Float
        /// The noise floor it was judged against; nil for the first buffer, which sets it.
        let noiseFloor: Float?
        let isVoice: Bool
    }

    private let detector = Mutex(VoiceActivityDetector())
    private let heardVoice = Atomic<Bool>(false)
    /// The loudest buffer's RMS level since `takePeakDecibels()` last ran, as its bit pattern.
    /// Non-negative floats order the same way as their bit patterns, so an integer max works.
    private let peakLevel = Atomic<UInt32>(0)

    /// Runs on the audio thread for each microphone buffer. Returns nil for an empty buffer.
    @discardableResult
    func process(_ samples: UnsafePointer<Float>, count: Int) -> Reading? {
        guard count > 0 else { return nil }
        var sum: Float = 0
        for index in 0..<count {
            sum += samples[index] * samples[index]
        }
        let rms = (sum / Float(count)).squareRoot()
        peakLevel.max(rms.bitPattern, ordering: .relaxed)
        let (noiseFloor, isVoice) = detector.withLock { detector in
            let noiseFloor = detector.noiseFloor
            return (noiseFloor, detector.process(rms: rms))
        }
        if isVoice {
            heardVoice.store(true, ordering: .relaxed)
        }
        return Reading(level: rms, noiseFloor: noiseFloor, isVoice: isVoice)
    }

    /// Whether voice was heard since the last call.
    func takeHeardVoice() -> Bool {
        heardVoice.exchange(false, ordering: .relaxed)
    }

    /// The loudest microphone buffer since the last call, in dBFS rounded to a whole number,
    /// for the logs. -120 stands for silence or no buffers.
    func takePeakDecibels() -> Int {
        Self.decibels(Float(bitPattern: peakLevel.exchange(0, ordering: .relaxed)))
    }

    /// An RMS level in dBFS rounded to a whole number, for the logs. -120 stands for silence.
    static func decibels(_ level: Float) -> Int {
        level > 0 ? max(-120, Int((20 * log10(level)).rounded())) : -120
    }
}
