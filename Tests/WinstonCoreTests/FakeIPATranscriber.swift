import Foundation
import Synchronization
import VoiceLoop

/// The IPA transcriber for tests: no model. It is available unless the test says otherwise, and
/// answers each request with the next answer the test gave it, or, once they run out, with "ə"
/// for each word of the chunk, holding each answer back while `holdsAnswers` is on. It notes
/// which requests were cancelled.
final class FakeIPATranscriber: IPATranscriber {
    private struct State {
        var availability = PronunciationSuggesterAvailability.available
        var answers: [Result<[TranscribedWord], any Error>] = []
        var chunks: [String] = []
        var requestNumbers: [Int] = []
        var holdsAnswers = false
        /// Held answers, by the number of their request.
        var heldAnswers: [Int: CheckedContinuation<Void, Never>] = [:]
        var cancelledRequests: [Int] = []
        var availabilityReads = 0
    }

    private let state = Mutex(State())

    var availability: PronunciationSuggesterAvailability {
        get {
            state.withLock { state in
                state.availabilityReads += 1
                return state.availability
            }
        }
        set { state.withLock { $0.availability = newValue } }
    }

    /// How many times `availability` has been read.
    var availabilityReads: Int { state.withLock { $0.availabilityReads } }

    /// What the requests get, in order: the first request the first answer, and on.
    var answers: [Result<[TranscribedWord], any Error>] {
        get { state.withLock { $0.answers } }
        set { state.withLock { $0.answers = newValue } }
    }

    /// The chunk of each request, oldest first.
    var chunks: [String] { state.withLock { $0.chunks } }

    /// Speak IPA's number for each request, oldest first.
    var requestNumbers: [Int] { state.withLock { $0.requestNumbers } }

    /// Lets the held answer of request `number` (the first is 0) go.
    func releaseAnswer(_ number: Int) {
        state.withLock { $0.heldAnswers.removeValue(forKey: number) }?.resume()
    }

    /// While true, each answer waits until `releaseAnswer(_:)` or `releaseAnswers()`.
    var holdsAnswers: Bool {
        get { state.withLock { $0.holdsAnswers } }
        set { state.withLock { $0.holdsAnswers = newValue } }
    }

    /// Answers waiting in `holdsAnswers`.
    var heldAnswers: Int { state.withLock { $0.heldAnswers.count } }

    /// The requests whose task was cancelled while they waited, by number (the first is 0), in
    /// the order they were cancelled. Their answers still come once released, as a model's may.
    var cancelledRequests: [Int] { state.withLock { $0.cancelledRequests } }

    /// Lets every held answer go.
    func releaseAnswers() {
        let held = state.withLock { state in
            defer { state.heldAnswers = [:] }
            return state.heldAnswers.values
        }
        for answer in held { answer.resume() }
    }

    func transcribe(_ chunk: String, request: Int, chunkIndex: Int) async throws -> [TranscribedWord] {
        let (number, answer, holds) = state.withLock { state in
            let number = state.chunks.count
            state.chunks.append(chunk)
            state.requestNumbers.append(request)
            let answer = number < state.answers.count ? state.answers[number] : .success(Self.schwas(for: chunk))
            return (number, answer, state.holdsAnswers)
        }
        if holds {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    state.withLock { $0.heldAnswers[number] = continuation }
                }
            } onCancel: {
                state.withLock { $0.cancelledRequests.append(number) }
            }
        }
        return try answer.get()
    }

    /// Each word of `chunk` said as "ə": IPA Kokoro can say.
    static func schwas(for chunk: String) -> [TranscribedWord] {
        SpeakIPAText.words(of: chunk).map { TranscribedWord(word: $0, ipa: "ə") }
    }
}
