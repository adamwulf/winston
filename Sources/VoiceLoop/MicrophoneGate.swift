@preconcurrency import AVFoundation
import Synchronization

/// Push-to-talk's mute between the microphone and the analyzer. While push-to-talk is on, only
/// audio captured during a hold gets through: the microphone tap turns every other frame into
/// silence of the same length, so the analyzer's timeline (`FedAudioClock`) runs on unbroken,
/// and gives the voice detector none of it. While push-to-talk is off, everything gets through.
///
/// A hold is set on the host clock: the main actor opens the gate when the button is pressed and
/// closes it when it is released. The tap judges each buffer frame by frame from its capture
/// time, so the words spoken right up to the release are kept although their buffer reaches the
/// tap a buffer length or more later, and audio captured before the press is muted although it
/// reaches the tap after it. Once a buffer reaches the release, the tap records where the hold
/// ended on the analyzer's timeline, for the main actor to take.
///
/// It is also the AirPods mute on macOS (`setMuted(_:)`): while muted, nothing gets through,
/// whatever push-to-talk does.
///
/// Shared by the main actor and the audio thread; a `Mutex` guards it.
final class MicrophoneGate: Sendable {
    private struct State {
        var isEnabled = false
        /// While set, every frame is silenced, with or without push-to-talk.
        var isMuted = false
        /// When the hold began, in host time. Nil while there is no hold for the tap to pass.
        var start: UInt64?
        /// When the hold ended, in host time. Nil while the button is held.
        var end: UInt64?
        /// When the next hold begins, if the button was pressed again before the tap reached
        /// `end`.
        var nextStart: UInt64?
        /// Where the latest hold ended on the analyzer's timeline, from when the tap reached its
        /// end until the main actor takes it.
        var heldThrough: CMTime?
    }

    private let state = Mutex(State())

    /// Turns push-to-talk on, muting the microphone except during a hold, or off. Either way,
    /// any hold is forgotten.
    func setEnabled(_ isEnabled: Bool) {
        state.withLock { $0 = State(isEnabled: isEnabled, isMuted: $0.isMuted) }
    }

    /// Mutes the microphone, letting nothing through until it is unmuted, or unmutes it.
    func setMuted(_ isMuted: Bool) {
        state.withLock { $0.isMuted = isMuted }
    }

    /// A hold begins at `hostTime`, which may be a moment from now. If the button was pressed
    /// again before the tap reached the last hold's release, this hold begins after that
    /// release, and at the earliest with the buffer after the one that reaches it.
    func open(at hostTime: UInt64) {
        state.withLock { state in
            if state.start == nil {
                state.start = hostTime
            } else if state.end != nil {
                state.nextStart = hostTime
            }
            state.heldThrough = nil
        }
    }

    /// The hold ends at `hostTime`. A hold pressed again before the tap reached the last
    /// release (see `open(at:)`) is too short to keep: it is dropped, and the last one ends as
    /// it was released.
    func close(at hostTime: UInt64) {
        state.withLock { state in
            if state.nextStart != nil {
                state.nextStart = nil
            } else if let start = state.start, state.end == nil {
                state.end = max(start, hostTime)
            }
        }
    }

    /// Forgets any hold, leaving push-to-talk on or off.
    func endHold() {
        state.withLock { $0 = State(isEnabled: $0.isEnabled, isMuted: $0.isMuted) }
    }

    /// Where the last hold ended on the analyzer's timeline, once, after the tap has reached
    /// its end.
    func takeHeldThrough() -> CMTime? {
        state.withLock { state in
            defer { state.heldThrough = nil }
            return state.heldThrough
        }
    }

    /// Runs on the audio thread for each microphone buffer: `frames` frames at `sampleRate`,
    /// the first captured at `captureTime` (host time), starting at `audioStart` on the
    /// analyzer's timeline, whose timescale is its sample rate. Returns the frames to keep: all
    /// of them while push-to-talk is off, and none while muted.
    func keptFrames(_ frames: AVAudioFrameCount, sampleRate: Double, capturedAt captureTime: UInt64, audioStart: CMTime) -> Range<Int> {
        let count = Int(frames)
        /// The frame captured at `hostTime`: 0 for a time before the buffer, `count` after it.
        func frame(at hostTime: UInt64) -> Int {
            guard hostTime > captureTime else { return 0 }
            let seconds = AVAudioTime.seconds(forHostTime: hostTime - captureTime)
            return min(count, Int((seconds * sampleRate).rounded()))
        }
        /// The frames push-to-talk keeps, muted or not. Once the buffer reaches the end of a
        /// hold, moves `state` on past it.
        func pushToTalkFrames(_ state: inout State) -> Range<Int> {
            guard state.isEnabled else { return 0..<count }
            guard let start = state.start else { return count..<count }
            let first = frame(at: start)
            guard let end = state.end else { return first..<count }
            let last = max(first, frame(at: end))
            if last < count {
                // This buffer reaches the end of the hold.
                if let next = state.nextStart {
                    // The loop carries on with the same utterance, so it needs no end.
                    state.start = next
                    state.nextStart = nil
                } else {
                    let analyzerFrames = (Double(last) * Double(audioStart.timescale) / sampleRate).rounded()
                    state.heldThrough = audioStart + CMTime(value: CMTimeValue(analyzerFrames), timescale: audioStart.timescale)
                    state.start = nil
                }
                state.end = nil
            }
            return first..<last
        }
        return state.withLock { state in
            let kept = pushToTalkFrames(&state)
            // A hold still ends where it was released, so its utterance is sent as usual.
            return state.isMuted ? count..<count : kept
        }
    }
}

/// Zeroes `buffer`'s frames outside `kept`, which makes them silent in a signed integer or
/// float format.
nonisolated func zeroFrames(of buffer: AVAudioPCMBuffer, outside kept: Range<Int>) {
    let frames = Int(buffer.frameLength)
    let kept = kept.clamped(to: 0..<frames)
    let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
    for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
        guard let data = channel.mData else { continue }
        if kept.isEmpty {
            data.initializeMemory(as: UInt8.self, repeating: 0, count: frames * bytesPerFrame)
            continue
        }
        data.initializeMemory(as: UInt8.self, repeating: 0, count: kept.lowerBound * bytesPerFrame)
        (data + kept.upperBound * bytesPerFrame)
            .initializeMemory(as: UInt8.self, repeating: 0, count: (frames - kept.upperBound) * bytesPerFrame)
    }
}
