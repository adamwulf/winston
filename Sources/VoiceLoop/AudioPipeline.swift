@preconcurrency import AVFoundation
import Speech
import Synchronization

/// The audio engine for one listening session: the microphone, normally with voice processing
/// on, feeding converted buffers to the analyzer, and a player node for speech in the same engine.
@MainActor
final class Pipeline {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    /// Whether voice processing (echo cancellation) is on. Without it the microphone also hears
    /// the speech the player plays.
    let hasVoiceProcessing: Bool
    /// The player's connection format; speech buffers are converted to it.
    let speechFormat: AVAudioFormat
    /// Microphone audio in the analyzer's format, for `SpeechAnalyzer.start(inputSequence:)`.
    let inputs: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    /// How far along the analyzer's timeline the fed audio reaches.
    let fedAudio: FedAudioClock
    /// Whether the microphone has heard someone talking, from its loudness.
    let voiceActivity = VoiceActivity()
    var analyzer: SpeechAnalyzer?
    var tasks: [Task<Void, Never>] = []
    private let analyzerFormat: AVAudioFormat

    /// `ducksOtherAudio` leaves voice processing's default ducking of other apps' audio in place.
    /// When false, it ducks them as little as it can.
    init(analyzerFormat: AVAudioFormat, voiceProcessing: Bool, ducksOtherAudio: Bool) throws {
        (inputs, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        fedAudio = FedAudioClock(sampleRate: analyzerFormat.sampleRate)
        hasVoiceProcessing = voiceProcessing
        self.analyzerFormat = analyzerFormat
        guard let speechFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            throw AudioFormatError()
        }
        self.speechFormat = speechFormat

        let input = engine.inputNode
        if voiceProcessing {
            // Echo cancellation: removes the player's output from the microphone signal.
            try input.setVoiceProcessingEnabled(true)
            if !ducksOtherAudio {
                // Voice processing turns other audio down while it runs. `.min` is the least it offers.
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )
            }
        }
        #if os(macOS)
        if voiceProcessing {
            // On a MacBook Pro with voice processing on, the input reports 9 identical channels,
            // and the engine won't start (-10875, "client-side input and output formats do not
            // match") while the output keeps its default stereo format. A mono output works.
            let inputFormat = input.outputFormat(forBus: 0)
            guard let outputFormat = AVAudioFormat(standardFormatWithSampleRate: inputFormat.sampleRate, channels: 1) else {
                throw AudioFormatError()
            }
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)
        }
        #endif
        try installMicrophoneTap()

        engine.attach(player)
        // Mono into the mixer, which spreads it to every output channel.
        engine.connect(player, to: engine.mainMixerNode, format: speechFormat)
        engine.prepare()
    }

    /// Taps the microphone in its current format, replacing any earlier tap. The format can
    /// change with the audio hardware, so `restartEngine()` taps it again.
    private func installMicrophoneTap() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
            throw AudioFormatError()
        }
        converter.primeMethod = .none
        if inputFormat.channelCount > 1 {
            // Use the first channel rather than a downmix; with voice processing on, the extra
            // channels repeat it.
            converter.channelMap = [0]
        }
        input.removeTap(onBus: 0)
        input.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: inputFormat,
            block: Self.microphoneTap(
                converter: converter,
                continuation: inputContinuation,
                clock: fedAudio,
                voiceActivity: voiceActivity
            )
        )
    }

    /// Starts the engine again after it stopped itself because the audio hardware changed,
    /// keeping voice processing, the player, and the analyzer's input stream, rather than
    /// building a new engine, which turns voice processing off and on again.
    func restartEngine() throws {
        try installMicrophoneTap()
        engine.prepare()
        try engine.start()
    }

    /// The audio formats and route the engine is using, for logs.
    var formatContext: [String: String] {
        let micFormat = engine.inputNode.inputFormat(forBus: 0)
        let tapFormat = engine.inputNode.outputFormat(forBus: 0)
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        var context = [
            "micFormat": "\(micFormat.sampleRate)/\(micFormat.channelCount)",
            "tapFormat": "\(tapFormat.sampleRate)/\(tapFormat.channelCount)",
            "outputFormat": "\(outputFormat.sampleRate)/\(outputFormat.channelCount)",
        ]
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        context["sessionRate"] = "\(session.sampleRate)"
        context["sessionMode"] = session.mode.rawValue
        context["route"] = (session.currentRoute.inputs + session.currentRoute.outputs)
            .map(\.portType.rawValue)
            .joined(separator: "+")
        #endif
        return context
    }

    func tearDown() {
        for task in tasks { task.cancel() }
        tasks = []
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        inputContinuation.finish()
    }

    /// Runs on the audio thread: measures each microphone buffer's loudness and converts it
    /// for the analyzer.
    private nonisolated static func microphoneTap(
        converter: AVAudioConverter,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        clock: FedAudioClock,
        voiceActivity: VoiceActivity
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            if let samples = buffer.floatChannelData?[0] {
                voiceActivity.process(samples, count: Int(buffer.frameLength))
            }
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
        /// The synthesizer has delivered every buffer.
        var isSynthesized = false
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

    /// Takes one synthesizer buffer.
    func receive(_ buffer: AVAudioBuffer) {
        state.withLock { state in
            guard !state.isCancelled, let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
            if state.converter?.inputFormat != pcm.format {
                state.converter = AVAudioConverter(from: pcm.format, to: state.format)
                state.converter?.primeMethod = .none
            }
            guard let converter = state.converter, let converted = convert(pcm, with: converter) else { return }
            if state.isSynthesized {
                // Arrived after the synthesizer said it was done; this buffer now ends the message.
                scheduleLast(converted, on: state.player)
                return
            }
            if let previous = state.pending {
                state.player.scheduleBuffer(previous)
            }
            state.pending = converted
        }
    }

    /// Called when the synthesizer has delivered every buffer
    /// (`AVSpeechSynthesizerDelegate.speechSynthesizer(_:didFinish:)`). The message finishes
    /// once the last buffer has played. The synthesizer doesn't reliably send a zero-length
    /// buffer at the end: on macOS 27 the last buffer has one frame.
    func synthesisFinished() {
        let finishedNow = state.withLock { state -> Bool in
            guard !state.isCancelled, !state.isSynthesized else { return false }
            state.isSynthesized = true
            guard let last = state.pending else { return true }
            state.pending = nil
            scheduleLast(last, on: state.player)
            return false
        }
        if finishedNow { onFinished(self) }
    }

    private func scheduleLast(_ buffer: AVAudioPCMBuffer, on player: AVAudioPlayerNode) {
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [self] _ in
            onFinished(self)
        }
    }

    /// Ignores any further buffers. The caller stops the player.
    func cancel() {
        state.withLock { state in
            state.isCancelled = true
            state.pending = nil
        }
    }
}

/// The synthesizer's delegate. Its only job is to tell the playback for the utterance being
/// written when synthesis has finished, since the buffer callback has no reliable end marker.
final class SynthesisObserver: NSObject, AVSpeechSynthesizerDelegate, Sendable {
    private let current = Mutex<(utterance: ObjectIdentifier, playback: SpeechPlayback)?>(nil)

    /// Call before `write(_:toBufferCallback:)`. `stopSpeaking(at:)` doesn't stop a write, so a
    /// cancelled utterance keeps synthesizing and its `didFinish` can arrive after the next
    /// write has started; the utterance identity check drops that stale callback.
    func track(_ utterance: AVSpeechUtterance, playback: SpeechPlayback) {
        current.withLock { $0 = (ObjectIdentifier(utterance), playback) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let playback = current.withLock { current -> SpeechPlayback? in
            guard let tracked = current, tracked.utterance == ObjectIdentifier(utterance) else { return nil }
            current = nil
            return tracked.playback
        }
        playback?.synthesisFinished()
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
