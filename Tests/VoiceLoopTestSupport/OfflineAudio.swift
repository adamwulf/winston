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
    /// How much sound has come out of the speaker: the rendered frames (at 48 kHz) that weren't
    /// silent. It depends on what was played, not on how fast the engine was pulled, so the
    /// same words always add the same amount. Only what the loop plays (speech, and sound cues
    /// when they are on) reaches the speaker; the microphone is kept out of it.
    package private(set) var playedFrames = 0
    /// How many times the sound out of the speaker crossed zero. A tone crosses twice per
    /// cycle, so per second of `playedFrames` this says how high the sound is.
    package private(set) var playedZeroCrossings = 0
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

        if nextEngineCannotStart {
            nextEngineCannotStart = false
            try makeUnstartable(engine)
        } else {
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            try feedMicrophone(to: input, in: inputFormat)
            // An offline engine only pulls its input node when the node feeds the output.
            // Muted there, so the speaker carries speech alone; the pipeline's tap still gets it.
            engine.connect(input, to: engine.mainMixerNode, format: inputFormat)
            input.volume = 0
        }

        engines.append(engine)
        startRendering()
        return engine
    }

    /// The audio hardware changes in a way `engine` can't follow: it stops, and starting it
    /// again fails, so the voice loop has to build a new engine.
    package func breakEngine(_ engine: AVAudioEngine) throws {
        engine.stop()
        engine.disconnectNodeOutput(engine.inputNode)
        try makeUnstartable(engine)
    }

    /// An offline engine fails to start (-10868) when its input is fed in a format other than
    /// the one its input node reports and the node feeds nothing.
    private func makeUnstartable(_ engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let reportedRate = input.outputFormat(forBus: 0).sampleRate
        guard let otherFormat = AVAudioFormat(
            standardFormatWithSampleRate: reportedRate == 48_000 ? 44_100 : 48_000,
            channels: 1
        ) else {
            throw OfflineAudioError.noRenderFormat
        }
        try feedMicrophone(to: input, in: otherFormat)
    }

    /// Makes the pretend microphone the source of `input`, in `format`.
    private func feedMicrophone(to input: AVAudioInputNode, in format: AVAudioFormat) throws {
        guard let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw OfflineAudioError.noMicrophoneBuffer
        }
        let microphone = microphone
        let accepted = input.setManualRenderingInputPCMFormat(format) { frameCount in
            microphone.fill(source, frameCount: frameCount)
            return UnsafePointer(source.audioBufferList)
        }
        guard accepted else { throw OfflineAudioError.microphoneFormatRejected }
    }

    /// Renders every running engine a few hundred times a second, far faster than real time,
    /// for as long as this object lives. It idles while no engine is running.
    private func startRendering() {
        guard renderTask == nil else { return }
        renderTask = Task { [weak self] in
            while true {
                guard let self else { return }
                let isRendering = self.renderOnce()
                try? await Task.sleep(for: .milliseconds(isRendering ? 2 : 50))
            }
        }
    }

    /// Renders one pass on each running engine. Returns false when none is running.
    private func renderOnce() -> Bool {
        let running = engines.filter { $0.isRunning && $0.isInManualRenderingMode }
        for engine in running {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat,
                frameCapacity: engine.manualRenderingMaximumFrameCount
            ) else { continue }
            // A failed render is the same as a sound card with nothing to play.
            guard (try? engine.renderOffline(output.frameCapacity, to: output)) != nil,
                  let samples = output.floatChannelData?[0] else { continue }
            let frames = Int(output.frameLength)
            playedFrames += (0..<frames).count { abs(samples[$0]) >= 0.001 }
            // Within each pass; a crossing between two passes is missed, one per 4096 frames.
            playedZeroCrossings += (0..<max(frames - 1, 0)).count { index in
                let sample = samples[index], next = samples[index + 1]
                return (sample < 0) != (next < 0) && max(abs(sample), abs(next)) >= 0.001
            }
        }
        return !running.isEmpty
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
