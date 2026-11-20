import Foundation
import Logging
import LogSupport
import Observation
import VoiceLoop

/// The suggested pronunciations of one word, for the list the Suggest button on an IPA
/// pronunciation opens in settings: loading, then the suggestions, or why there are none.
/// `generate()` asks again, for Regenerate. The suggestions are kept as the suggester gave them
/// (trimmed, without repeats); `candidates` checks them against the symbols Kokoro has each time
/// it is read, so a suggestion the fallback symbols lacked can be used once the Kokoro model is
/// ready, with nothing asked again. Made by `AppModel.pronunciationSuggestions(for:)`.
@MainActor
@Observable
public final class PronunciationSuggestions: Identifiable {
    private static let log = Logger(label: "app.suggestions")

    /// Where the latest request is.
    public enum Phase: Equatable, Sendable {
        /// Waiting for the suggester.
        case loading
        /// The suggester's suggestions as settings lists them (see
        /// `PronunciationSuggestion.listed(_:)`), perhaps none.
        case loaded([PronunciationSuggestion])
        /// The suggester failed: what to tell the user.
        case failed(String)
    }

    /// The word, trimmed.
    public let word: String
    public private(set) var phase: Phase = .loading
    /// Where the suggestions come from, for the list's footer: the suggester's own words.
    public var attribution: String { suggester.attribution }
    @ObservationIgnored private let suggester: any PronunciationSuggester
    /// The phoneme symbols Kokoro has now: for `AppModel`'s, `VoiceLoop.kokoroPhonemeSymbols`,
    /// which is observable, so a view showing `candidates` follows it.
    @ObservationIgnored private let symbols: @MainActor () -> Set<Character>
    /// Told each time a request's answer has been handled, shown or dropped. Nothing in the app;
    /// tests can't otherwise see that an answer was dropped.
    @ObservationIgnored private let answerHandled: @MainActor () -> Void
    /// The latest request, until it finishes.
    @ObservationIgnored private var request: Task<Void, Never>?
    /// Counts the requests, so a request that a newer one replaced changes nothing when it ends.
    @ObservationIgnored private var requestCount = 0

    init(
        word: String,
        suggester: any PronunciationSuggester,
        symbols: @escaping @MainActor () -> Set<Character>,
        answerHandled: @escaping @MainActor () -> Void = {}
    ) {
        self.word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        self.suggester = suggester
        self.symbols = symbols
        self.answerHandled = answerHandled
    }

    /// The suggestions loaded, each checked against the symbols Kokoro has now; none while
    /// loading or after a failure.
    public var candidates: [PronunciationCandidate] {
        guard case .loaded(let suggestions) = phase else { return [] }
        let symbols = symbols()
        return suggestions.map { PronunciationCandidate($0, symbols: symbols) }
    }

    /// Asks the suggester for the word's pronunciations, replacing any request under way: the
    /// first time, and for Regenerate. Loading until it answers.
    public func generate() {
        request?.cancel()
        requestCount += 1
        let number = requestCount
        phase = .loading
        let started = ContinuousClock.now
        request = Task { [word, suggester] in
            let result: Result<[PronunciationSuggestion], any Error>
            do {
                result = .success(try await suggester.suggestions(for: word))
            } catch {
                result = .failure(error)
            }
            defer { self.answerHandled() }
            // Replaced by a newer request, or the list closed.
            guard number == self.requestCount else { return }
            self.request = nil
            switch result {
            case .success(let suggestions):
                let listed = PronunciationSuggestion.listed(suggestions)
                self.phase = .loaded(listed)
                // Counts only: the word and the phonemes are the user's.
                Self.log.info("pronunciation suggestions listed", [
                    "suggestions": suggestions.count,
                    "listed": listed.count,
                    "usable": self.candidates.count { $0.isUsable },
                    "ms": Int(started.duration(to: .now) / .milliseconds(1)),
                ])
            case .failure(let error):
                // Codes only: a suggester's error can quote the word.
                Self.log.warning("pronunciation suggestions failed", error.logCodes())
                self.phase = .failed(userMessage(for: error))
            }
        }
    }

    /// Stops the request under way, as the list closes.
    public func cancel() {
        request?.cancel()
        request = nil
        requestCount += 1
    }
}
