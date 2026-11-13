@preconcurrency import AVFoundation
import Speech
import Synchronization

/// The audio engine for one listening session: the microphone, with voice processing on,
/// feeding converted buffers to the analyzer, and a player node for speech in the same engine.
@MainActor
final class Pipeline {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    /// The player's connection format; speech buffers are converted to it.
    let speechFormat: AVAudioFormat
    /// Microphone audio in the analyzer's format, for `SpeechAnalyzer.start(inputSequence:)`.
    let inputs: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    /// How far along the analyzer's timeline the fed audio reaches.
    let fedAudio: FedAudioClock
    var analyzer: SpeechAnalyzer?
    var tasks: [Task<Void, Never>] = []

    init(analyzerFormat: AVAudioFormat) throws {
        (inputs, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        fedAudio = FedAudioClock(sampleRate: analyzerFormat.sampleRate)

        let input = engine.inputNode
        // Echo cancellation: removes the player's output from the microphone signal.
        try input.setVoiceProcessingEnabled(true)
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat),
              let speechFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            throw AudioFormatError()
        }
        self.speechFormat = speechFormat
        converter.primeMethod = .none
        input.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: inputFormat,
            block: Self.microphoneTap(converter: converter, continuation: inputContinuation, clock: fedAudio)
        )

        engine.attach(player)
        // Mono into the mixer, which spreads it to every output channel.
        engine.connect(player, to: engine.mainMixerNode, format: speechFormat)
        engine.prepare()
    }

    func tearDown() {
        for task in tasks { task.cancel() }
        tasks = []
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        inputContinuation.finish()
    }

    /// Runs on the audio thread: converts each microphone buffer for the analyzer.
    private nonisolated static func microphoneTap(
        converter: AVAudioConverter,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        clock: FedAudioClock
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let converted = convert(buffer, with: converter) else { return }
            clock.add(frames: converted.frameLength)
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }
}

/// The analyzer's timeline position: the audio fed to it so far, in its format. The timeline
/// starts at 0 and each `AnalyzerInput(buffer:)` follows straight on from the previous one.
/// Written on the audio thread, read on the main actor.
final class FedAudioClock: Sendable {
    let sampleRate: Double
    private let frames = Atomic<Int64>(0)

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    func add(frames count: AVAudioFrameCount) {
        frames.wrappingAdd(Int64(count), ordering: .relaxed)
    }

    var time: CMTime {
        CMTime(value: frames.load(ordering: .relaxed), timescale: CMTimeScale(sampleRate.rounded()))
    }
}

/// The microphone or speech audio format can't be converted for the engine.
struct AudioFormatError: Error {}

/// Plays one spoken message: converts the synthesizer's buffers to the player's format and
/// schedules them. `receive(_:)` runs on the synthesizer's callback thread; the lock keeps it
/// from racing `cancel()` on the main actor.
final class SpeechPlayback: Sendable {
    private struct State {
        let player: AVAudioPlayerNode
        /// The player's connection format.
        let format: AVAudioFormat
        var converter: AVAudioConverter?
        /// Held back until the next buffer arrives, so the last one can carry the completion handler.
        var pending: AVAudioPCMBuffer?
        var isCancelled = false
    }

    /// The message being spoken, so it can be queued again if playback is cut off.
    let text: String
    private let state: Mutex<State>
    private let onFinished: @Sendable (SpeechPlayback) -> Void

    /// `format` is the player's connection format. `onFinished` is called, on an arbitrary
    /// thread, once the last buffer has played.
    init(
        text: String,
        player: AVAudioPlayerNode,
        format: AVAudioFormat,
        onFinished: @escaping @Sendable (SpeechPlayback) -> Void
    ) {
        self.text = text
        state = Mutex(State(player: player, format: format))
        self.onFinished = onFinished
    }

    /// Takes one synthesizer buffer. A zero-length buffer marks the end of the message.
    func receive(_ buffer: AVAudioBuffer) {
        let finishedNow = state.withLock { state -> Bool in
            guard !state.isCancelled, let pcm = buffer as? AVAudioPCMBuffer else { return false }
            if pcm.frameLength == 0 {
                guard let last = state.pending else { return true }
                state.pending = nil
                state.player.scheduleBuffer(last, completionCallbackType: .dataPlayedBack) { [self] _ in
                    onFinished(self)
                }
                return false
            }
            if state.converter?.inputFormat != pcm.format {
                state.converter = AVAudioConverter(from: pcm.format, to: state.format)
                state.converter?.primeMethod = .none
            }
            guard let converter = state.converter, let converted = convert(pcm, with: converter) else { return false }
            if let previous = state.pending {
                state.player.scheduleBuffer(previous)
            }
            state.pending = converted
            return false
        }
        if finishedNow { onFinished(self) }
    }

    /// Ignores any further buffers. The caller stops the player.
    func cancel() {
        state.withLock { state in
            state.isCancelled = true
            state.pending = nil
        }
    }
}

/// Converts `buffer` with `converter`, which keeps its resampling state between calls.
/// Returns nil on failure or when no output is ready yet.
nonisolated func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
    let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
    guard capacity > 0,
          let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }
    nonisolated(unsafe) var supplied = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
        guard !supplied else {
            inputStatus.pointee = .noDataNow
            return nil
        }
        supplied = true
        inputStatus.pointee = .haveData
        return buffer
    }
    guard status != .error, output.frameLength > 0 else { return nil }
    return output
}
