@preconcurrency import AVFoundation
import CoreMedia
import Speech
import Synchronization
import VoiceLoop

/// A recognizer that reports what the test tells it to, in place of the on-device speech model.
/// It still reads the microphone audio the pipeline feeds it, and counts the frames.
package final class ScriptedRecognizer: Recognizer {
    private struct State {
        var startError: (any Error)?
        var isStarted = false
        var isCancelled = false
        var heardFrames = 0
    }

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
                state.withLock { $0.heardFrames += frames }
            }
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
        continuation.yield(.spoken(text, over: seconds, isFinal: isFinal, alternatives: alternatives))
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
