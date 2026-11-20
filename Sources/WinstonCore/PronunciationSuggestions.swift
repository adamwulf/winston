import Foundation
import Logging
import LogSupport
import Observation
import VoiceLoop

/// The suggested pronunciations of one word, for the list the Suggest button on an IPA
/// pronunciation opens in settings: loading, then the candidates (see `PronunciationCandidate`),
/// or why there are none. `generate()` asks again, for Regenerate. Made by
/// `AppModel.pronunciationSuggestions(for:)`.
@MainActor
@Observable
public final class PronunciationSuggestions: Identifiable {
    private static let log = Logger(label: "app.suggestions")

    /// Where the latest request is.
    public enum Phase: Equatable, Sendable {
        /// Waiting for the suggester.
        case loading
        /// The suggester's candidates, perhaps none.
        case loaded([PronunciationCandidate])
        /// The suggester failed: what to tell the user.
        case failed(String)
    }

    /// The word, trimmed.
    public let word: String
    public private(set) var phase: Phase = .loading
    @ObservationIgnored private let suggester: any PronunciationSuggester
    /// The phoneme symbols Kokoro has, read after each request: `VoiceLoop.kokoroPhonemeSymbols()`.
    @ObservationIgnored private let symbols: @MainActor () async -> Set<Character>
    /// The latest request, until it finishes.
    @ObservationIgnored private var request: Task<Void, Never>?
    /// Counts the requests, so a request that a newer one replaced changes nothing when it ends.
    @ObservationIgnored private var requestCount = 0

    init(word: String, suggester: any PronunciationSuggester, symbols: @escaping @MainActor () async -> Set<Character>) {
        self.word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        self.suggester = suggester
        self.symbols = symbols
    }

    /// Asks the suggester for the word's pronunciations, replacing any request under way: the
    /// first time, and for Regenerate. Loading until it answers.
    public func generate() {
        request?.cancel()
        requestCount += 1
        let number = requestCount
        phase = .loading
        let started = ContinuousClock.now
        request = Task { [word, suggester, symbols] in
            let result: Result<[PronunciationSuggestion], any Error>
            do {
                result = .success(try await suggester.suggestions(for: word))
            } catch {
                result = .failure(error)
            }
            let symbols = await symbols()
            // Replaced by a newer request, or the list closed.
            guard number == self.requestCount else { return }
            self.request = nil
            switch result {
            case .success(let suggestions):
                let candidates = PronunciationCandidate.candidates(from: suggestions, symbols: symbols)
                // Counts only: the word and the phonemes are the user's.
                Self.log.info("pronunciation suggestions listed", [
                    "suggestions": suggestions.count,
                    "candidates": candidates.count,
                    "usable": candidates.count { $0.isUsable },
                    "ms": Int(started.duration(to: .now) / .milliseconds(1)),
                ])
                self.phase = .loaded(candidates)
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
