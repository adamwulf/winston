import Foundation
import Synchronization
import VoiceLoop

/// The pronunciation suggester for tests: no model. It is available unless the test says
/// otherwise, and answers each request with the next answer the test gave it (or with none, once
/// they run out), holding each answer back while `holdsAnswers` is on. It notes which requests
/// were cancelled.
final class FakePronunciationSuggester: PronunciationSuggester {
    private struct State {
        var availability = PronunciationSuggesterAvailability.available
        var answers: [Result<[PronunciationSuggestion], PronunciationSuggestionError>] = []
        var words: [String] = []
        var holdsAnswers = false
        /// Held answers, by the number of their request.
        var heldAnswers: [Int: CheckedContinuation<Void, Never>] = [:]
        var cancelledRequests: [Int] = []
    }

    private let state = Mutex(State())

    let attribution = "Suggested by the fake suggester."

    var availability: PronunciationSuggesterAvailability {
        get { state.withLock { $0.availability } }
        set { state.withLock { $0.availability = newValue } }
    }

    /// What the requests get, in order: the first request the first answer, and on.
    var answers: [Result<[PronunciationSuggestion], PronunciationSuggestionError>] {
        get { state.withLock { $0.answers } }
        set { state.withLock { $0.answers = newValue } }
    }

    /// The word of each request, oldest first.
    var words: [String] { state.withLock { $0.words } }

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

    /// Lets the held answer of request `number` (the first is 0) go.
    func releaseAnswer(_ number: Int) {
        state.withLock { $0.heldAnswers.removeValue(forKey: number) }?.resume()
    }

    /// Lets every held answer go.
    func releaseAnswers() {
        let held = state.withLock { state in
            defer { state.heldAnswers = [:] }
            return state.heldAnswers.values
        }
        for answer in held { answer.resume() }
    }

    func suggestions(for word: String, request: Int) async throws -> [PronunciationSuggestion] {
        let (number, answer, holds) = state.withLock { state in
            let number = state.words.count
            state.words.append(word)
            let answer = number < state.answers.count ? state.answers[number] : .success([])
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
}
