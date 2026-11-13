@preconcurrency import AVFoundation
import Synchronization

/// The audio hardware for tests. Its engines are real `AVAudioEngine`s in offline manual
/// rendering mode, so they need no microphone or speaker, and a timer pulls audio through
/// them the way a sound card does. The microphone is pretend: silence, or a tone loud enough to
/// count as someone talking.
@MainActor
package final class OfflineAudio {
    /// Every engine made so far, newest last. The voice loop makes one per pipeline.
    package private(set) var engines: [AVAudioEngine] = []
    /// How much sound has come out of the speaker: the frames rendered (at 48 kHz) in passes
    /// that weren't silent. Only speech reaches the speaker; the microphone is kept out of it.
    package private(set) var playedFrames = 0
    /// When true, the next engine made can't start, as when the hardware rejects the formats.
    package var nextEngineCannotStart = false
    private let microphone = Microphone()
    private var renderTask: Task<Void, Never>?

    package init() {}

    /// Whether the pretend microphone hears someone talking.
    package var isVoicePresent: Bool {
        get { microphone.isVoicePresent.load(ordering: .relaxed) }
        set { microphone.isVoicePresent.store(newValue, ordering: .relaxed) }
    }

    /// A new engine that renders offline, with the pretend microphone as its input.
    package func makeEngine() throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        guard let renderFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            throw OfflineAudioError.noRenderFormat
        }
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 4096)

        let input = engine.inputNode
        // An engine fed in a format other than the one its input node reports, and whose
        // input feeds nothing, fails to start (-10868).
        let cannotStart = nextEngineCannotStart
        nextEngineCannotStart = false
        let inputFormat = cannotStart ? renderFormat : input.outputFormat(forBus: 0)
        guard let source = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 16_384) else {
            throw OfflineAudioError.noMicrophoneBuffer
        }
        let microphone = microphone
        let accepted = input.setManualRenderingInputPCMFormat(inputFormat) { frameCount in
            microphone.fill(source, frameCount: frameCount)
            return UnsafePointer(source.audioBufferList)
        }
        guard accepted else { throw OfflineAudioError.microphoneFormatRejected }
        if !cannotStart {
            // An offline engine only pulls its input node when the node feeds the output.
            // Muted there, so the speaker carries speech alone; the pipeline's tap still gets it.
            engine.connect(input, to: engine.mainMixerNode, format: inputFormat)
            input.volume = 0
        }

        engines.append(engine)
        startRendering()
        return engine
    }

    /// Renders every running engine a few hundred times a second, far faster than real time.
    private func startRendering() {
        guard renderTask == nil else { return }
        renderTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.renderOnce()
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    private func renderOnce() {
        for engine in engines where engine.isRunning && engine.isInManualRenderingMode {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat,
                frameCapacity: engine.manualRenderingMaximumFrameCount
            ) else { continue }
            // A failed render is the same as a sound card with nothing to play.
            guard (try? engine.renderOffline(output.frameCapacity, to: output)) != nil,
                  let samples = output.floatChannelData?[0] else { continue }
            let isSilent = (0..<Int(output.frameLength)).allSatisfy { abs(samples[$0]) < 0.001 }
            if !isSilent {
                playedFrames += Int(output.frameLength)
            }
        }
    }
}

package enum OfflineAudioError: Error {
    case noRenderFormat
    case noMicrophoneBuffer
    case microphoneFormatRejected
}

/// What the offline engines' input nodes read.
private final class Microphone: Sendable {
    let isVoicePresent = Atomic<Bool>(false)
    /// Frames read so far, which is the microphone's clock.
    private let framesRead = Atomic<Int>(0)

    /// Fills `buffer` with `frameCount` frames: silence, or someone talking. Talking is a
    /// 440 Hz tone at half scale in bursts (0.4 s of every second of audio), because a steady
    /// tone is soon taken for a loud room, not a voice.
    func fill(_ buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) {
        let frames = min(frameCount, buffer.frameCapacity)
        buffer.frameLength = frames
        guard let channels = buffer.floatChannelData else { return }
        let sampleRate = buffer.format.sampleRate
        let start = framesRead.add(Int(frames), ordering: .relaxed).oldValue
        let isTalking = isVoicePresent.load(ordering: .relaxed)
        let step = 2 * Float.pi * 440 / Float(sampleRate)
        for frame in 0..<Int(frames) {
            let seconds = Double(start + frame) / sampleRate
            let isBurst = isTalking && seconds.truncatingRemainder(dividingBy: 1) < 0.4
            let sample = isBurst ? 0.5 * sinf(step * Float(start + frame)) : 0
            for channel in 0..<Int(buffer.format.channelCount) {
                channels[channel][frame] = sample
            }
        }
    }
}
