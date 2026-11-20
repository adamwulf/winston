import Foundation
import Synchronization
import VoiceLoop

/// The pronunciation suggester for tests: no model. It is available while the test says so, and
/// answers each request with the next answer the test gave it (or with none, once they run out),
/// holding each answer back while `holdsAnswers` is on.
final class FakePronunciationSuggester: PronunciationSuggester {
    private struct State {
        var isAvailable = true
        var answers: [Result<[PronunciationSuggestion], PronunciationSuggestionError>] = []
        var words: [String] = []
        var holdsAnswers = false
        var heldAnswers: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var isAvailable: Bool {
        get { state.withLock { $0.isAvailable } }
        set { state.withLock { $0.isAvailable = newValue } }
    }

    /// What the requests get, in order: the first request the first answer, and on.
    var answers: [Result<[PronunciationSuggestion], PronunciationSuggestionError>] {
        get { state.withLock { $0.answers } }
        set { state.withLock { $0.answers = newValue } }
    }

    /// The word of each request, oldest first.
    var words: [String] { state.withLock { $0.words } }

    /// While true, each answer waits until `releaseAnswers()`.
    var holdsAnswers: Bool {
        get { state.withLock { $0.holdsAnswers } }
        set { state.withLock { $0.holdsAnswers = newValue } }
    }

    /// Answers waiting in `holdsAnswers`.
    var heldAnswers: Int { state.withLock { $0.heldAnswers.count } }

    /// Lets every held answer go.
    func releaseAnswers() {
        let held = state.withLock { state in
            defer { state.heldAnswers = [] }
            return state.heldAnswers
        }
        for answer in held { answer.resume() }
    }

    func suggestions(for word: String) async throws -> [PronunciationSuggestion] {
        let (answer, holds) = state.withLock { state in
            let index = state.words.count
            state.words.append(word)
            let answer = index < state.answers.count ? state.answers[index] : .success([])
            return (answer, state.holdsAnswers)
        }
        if holds {
            // Not cancelled with its task, as a model may not be: an answer replaced by a newer
            // request still comes.
            await withCheckedContinuation { continuation in
                state.withLock { $0.heldAnswers.append(continuation) }
            }
        }
        return try answer.get()
    }
}
