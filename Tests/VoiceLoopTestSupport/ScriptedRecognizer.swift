@preconcurrency import AVFoundation
import CoreMedia
import Speech
import Synchronization
import VoiceLoop

/// A recognizer that reports what the test tells it to, in place of the on-device speech model.
/// It still reads the microphone audio the pipeline feeds it, counts the frames, and notes
/// where it was loud. Asked to finalize, it does what the analyzer does: waits until it has read
/// that far, then reports the last volatile result again as final.
package final class ScriptedRecognizer: Recognizer {
    private struct State {
        var startError: (any Error)?
        var isStarted = false
        var isCancelled = false
        /// The pipeline finished the input.
        var inputEnded = false
        var heardFrames = 0
        /// The first and the last loud frame read, counted from the start of the input.
        var loudFrames: ClosedRange<Int>?
        /// The latest result reported, if it was volatile.
        var lastVolatile: TranscriptPiece?
        var finalizations: [CMTime] = []
        var whenFinalizing: (@MainActor @Sendable (CMTime) async -> Void)?
    }

    /// A sample at least this far from zero is loud: about -30 dBFS.
    private static let loudSample: Int16 = 1000

    package let audioFormat: AVAudioFormat
    private let stream: AsyncThrowingStream<TranscriptPiece, any Error>
    private let continuation: AsyncThrowingStream<TranscriptPiece, any Error>.Continuation
    private let state = Mutex(State())
    private let whenStarting: @MainActor @Sendable () async -> Void

    /// - Parameters:
    ///   - startError: makes `start(inputs:)` throw, as when the analyzer can't start.
    ///   - whenStarting: runs inside `start(inputs:)`, for tests of what happens meanwhile.
    package init(
        startError: (any Error)? = nil,
        whenStarting: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        // The speech model takes 16 kHz 16-bit mono.
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            preconditionFailure("16 kHz 16-bit mono is a valid audio format")
        }
        audioFormat = format
        (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptPiece.self)
        state.withLock { $0.startError = startError }
        self.whenStarting = whenStarting
    }

    // MARK: - Recognizer

    package var results: any AsyncSequence<TranscriptPiece, any Error> {
        stream
    }

    /// It reports whenever the test says, so it has no option to make that sooner.
    package var reportsFastResults: Bool {
        false
    }

    package func start(inputs: AsyncStream<AnalyzerInput>) async throws {
        await whenStarting()
        if let error = state.withLock({ $0.startError }) {
            throw error
        }
        state.withLock { $0.isStarted = true }
        Task {
            for await input in inputs {
                let frames = Int(input.buffer.frameLength)
                let loud = Self.loudFrames(in: input.buffer)
                state.withLock { state in
                    if let loud {
                        let first = state.loudFrames?.lowerBound ?? state.heardFrames + loud.lowerBound
                        state.loudFrames = first...(state.heardFrames + loud.upperBound)
                    }
                    state.heardFrames += frames
                }
            }
            state.withLock { $0.inputEnded = true }
        }
    }

    /// The first and the last loud frame of `buffer`, which is in `audioFormat`; nil if none is.
    private static func loudFrames(in buffer: AVAudioPCMBuffer) -> ClosedRange<Int>? {
        guard let samples = buffer.int16ChannelData?[0] else { return nil }
        let frames = 0..<Int(buffer.frameLength)
        let isLoud = { (frame: Int) in abs(Int(samples[frame])) >= Int(loudSample) }
        guard let first = frames.first(where: isLoud), let last = frames.last(where: isLoud) else { return nil }
        return first...last
    }

    /// As the analyzer does: waits until it has read the audio through `time`, then reports the
    /// last volatile result again as final if it starts before `time`. `whenFinalizing` runs in
    /// between. Throws if it is cancelled, or the input ends first.
    package func finalize(through time: CMTime) async throws {
        let frames = Int((time.seconds * audioFormat.sampleRate).rounded(.up))
        while heardFrames < frames {
            if state.withLock({ $0.isCancelled || $0.inputEnded }) {
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let whenFinalizing = state.withLock { state in
            state.finalizations.append(time)
            return state.whenFinalizing
        }
        await whenFinalizing?(time)
        try Task.checkCancellation()
        let volatile = state.withLock { state in
            defer { state.lastVolatile = nil }
            return state.lastVolatile
        }
        if var final = volatile, final.range.start < time {
            final.isFinal = true
            continuation.yield(final)
        }
    }

    package func cancel() async {
        state.withLock { $0.isCancelled = true }
        continuation.finish()
    }

    // MARK: - What the tests script and read

    /// Reports a result: `text` heard over `seconds` of the audio timeline. A volatile result
    /// unless `isFinal`. `alternatives` are other readings of the same audio.
    package func hear(
        _ text: String,
        over seconds: ClosedRange<Double>,
        isFinal: Bool = false,
        alternatives: [String] = []
    ) {
        let piece = TranscriptPiece.spoken(text, over: seconds, isFinal: isFinal, alternatives: alternatives)
        state.withLock { $0.lastVolatile = isFinal ? nil : piece }
        continuation.yield(piece)
    }

    /// Runs inside `finalize(through:)` with the time it was given, once it has read that far
    /// and before the last volatile result is reported as final: for a test to report what the
    /// analyzer finalizes then, or to hold it up.
    package var whenFinalizing: (@MainActor @Sendable (CMTime) async -> Void)? {
        get { state.withLock { $0.whenFinalizing } }
        set { state.withLock { $0.whenFinalizing = newValue } }
    }

    /// The times `finalize(through:)` was asked to reach, in seconds, oldest first.
    package var finalizations: [Double] {
        state.withLock { $0.finalizations.map(\.seconds) }
    }

    /// The stretch of the timeline from the first to the last loud sample it has been fed, in
    /// seconds rounded inwards to whole milliseconds, so words scripted over it fall inside the
    /// audio that was loud. Nil while all it has been fed is quiet.
    package var soundHeard: ClosedRange<Double>? {
        let loud = state.withLock { $0.loudFrames }
        guard let loud else { return nil }
        let start = (Double(loud.lowerBound) / audioFormat.sampleRate * 1000).rounded(.up) / 1000
        let end = (Double(loud.upperBound) / audioFormat.sampleRate * 1000).rounded(.down) / 1000
        return start <= end ? start...end : nil
    }

    /// Ends the results with an error, as when the speech model fails.
    package func fail(_ error: any Error) {
        continuation.finish(throwing: error)
    }

    /// Ends the results, as when the speech model stops by itself.
    package func finish() {
        continuation.finish()
    }

    /// Whether `start(inputs:)` has succeeded.
    package var isStarted: Bool {
        state.withLock { $0.isStarted }
    }

    /// Whether the loop cancelled this recognizer.
    package var isCancelled: Bool {
        state.withLock { $0.isCancelled }
    }

    /// How many frames of microphone audio it has been fed, in `audioFormat`.
    package var heardFrames: Int {
        state.withLock { $0.heardFrames }
    }
}

extension TranscriptPiece {
    /// A result as the transcriber reports it: each reading is one run carrying the audio time
    /// range, and the result covers the same range.
    package static func spoken(
        _ text: String,
        over seconds: ClosedRange<Double>,
        isFinal: Bool = false,
        alternatives: [String] = []
    ) -> TranscriptPiece {
        let range = CMTimeRange(
            start: CMTime(seconds: seconds.lowerBound, preferredTimescale: 1000),
            end: CMTime(seconds: seconds.upperBound, preferredTimescale: 1000)
        )
        func timed(_ string: String) -> AttributedString {
            var attributed = AttributedString(string)
            attributed.audioTimeRange = range
            return attributed
        }
        return TranscriptPiece(
            text: timed(text),
            alternatives: alternatives.map(timed),
            range: range,
            isFinal: isFinal
        )
    }
}
