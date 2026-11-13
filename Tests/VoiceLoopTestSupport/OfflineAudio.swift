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
        let inputFormat = input.outputFormat(forBus: 0)
        guard let source = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 16_384) else {
            throw OfflineAudioError.noMicrophoneBuffer
        }
        let microphone = microphone
        let accepted = input.setManualRenderingInputPCMFormat(inputFormat) { frameCount in
            microphone.fill(source, frameCount: frameCount)
            return UnsafePointer(source.audioBufferList)
        }
        guard accepted else { throw OfflineAudioError.microphoneFormatRejected }
        // An offline engine only pulls its input node when the node feeds the output.
        engine.connect(input, to: engine.mainMixerNode, format: inputFormat)

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
            // A failed render (the engine stopped mid-way) is the same as a sound card with nothing to play.
            _ = try? engine.renderOffline(output.frameCapacity, to: output)
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

    /// Fills `buffer` with `frameCount` frames: a 440 Hz tone at half scale, or silence.
    func fill(_ buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) {
        let frames = min(frameCount, buffer.frameCapacity)
        buffer.frameLength = frames
        guard let channels = buffer.floatChannelData else { return }
        let level: Float = isVoicePresent.load(ordering: .relaxed) ? 0.5 : 0
        let step = 2 * Float.pi * 440 / Float(buffer.format.sampleRate)
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(frames) {
                channels[channel][frame] = level * sinf(step * Float(frame))
            }
        }
    }
}
