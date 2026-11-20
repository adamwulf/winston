import Foundation
import Logging
import LogSupport
import Observation
import VoiceLoop

/// The suggested pronunciations of one word, for the list the Suggest button on an IPA
/// pronunciation opens in settings: loading, then the candidates (see `PronunciationCandidate`),
/// or why there are none. `generate()` asks again, for Regenerate. The candidates shown are
/// checked again, without asking the suggester, when the symbols Kokoro has may have changed:
/// one that the fallback symbols lacked can be used once the Kokoro model is ready. Made by
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
    /// Where the suggestions come from, for the list's footer: the suggester's own words.
    public var attribution: String { suggester.attribution }
    @ObservationIgnored private let suggester: any PronunciationSuggester
    /// The phoneme symbols Kokoro has, read after each request: `VoiceLoop.kokoroPhonemeSymbols()`.
    @ObservationIgnored private let symbols: @MainActor () async -> Set<Character>
    /// Reads the observable state `symbols` depends on, so the list can watch it change: for
    /// `AppModel`'s, the Kokoro model's state.
    @ObservationIgnored private let readSymbolsSource: @MainActor () -> Void
    /// The latest request, until it finishes.
    @ObservationIgnored private var request: Task<Void, Never>?
    /// Counts the requests, so a request that a newer one replaced changes nothing when it ends.
    @ObservationIgnored private var requestCount = 0
    /// The suggestions the candidates shown came from, to check against Kokoro's symbols again.
    /// Nil while a request is under way, and after a failure.
    @ObservationIgnored private var shownSuggestions: [PronunciationSuggestion]?
    /// Whether the list watches `readSymbolsSource`: from the first answer shown until it closes.
    @ObservationIgnored private var watchesSymbols = false

    init(
        word: String,
        suggester: any PronunciationSuggester,
        symbols: @escaping @MainActor () async -> Set<Character>,
        readSymbolsSource: @escaping @MainActor () -> Void = {}
    ) {
        self.word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        self.suggester = suggester
        self.symbols = symbols
        self.readSymbolsSource = readSymbolsSource
    }

    /// Asks the suggester for the word's pronunciations, replacing any request under way: the
    /// first time, and for Regenerate. Loading until it answers.
    public func generate() {
        request?.cancel()
        requestCount += 1
        let number = requestCount
        phase = .loading
        shownSuggestions = nil
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
                self.shownSuggestions = suggestions
                self.watchSymbols()
            case .failure(let error):
                // Codes only: a suggester's error can quote the word.
                Self.log.warning("pronunciation suggestions failed", error.logCodes())
                self.phase = .failed(userMessage(for: error))
            }
        }
    }

    /// Stops the request under way, and the watch on Kokoro's symbols, as the list closes.
    public func cancel() {
        request?.cancel()
        request = nil
        requestCount += 1
        watchesSymbols = false
    }

    /// Watches `readSymbolsSource` until the list closes, checking the candidates shown again
    /// after each change.
    private func watchSymbols() {
        guard !watchesSymbols else { return }
        watchesSymbols = true
        observeSymbolsSource()
    }

    private func observeSymbolsSource() {
        withObservationTracking {
            readSymbolsSource()
        } onChange: { [weak self] in
            // Called just before the change, so the check, on the main actor's next turn, reads
            // the symbols after it. Watching again first catches a change during the check.
            Task { @MainActor in
                guard let self, self.watchesSymbols else { return }
                self.observeSymbolsSource()
                await self.checkSymbolsAgain()
            }
        }
    }

    /// Checks the suggestions shown against Kokoro's symbols again, without asking the
    /// suggester. Nothing if a request started or the list closed meanwhile.
    private func checkSymbolsAgain() async {
        guard let suggestions = shownSuggestions else { return }
        let number = requestCount
        let symbols = await symbols()
        guard number == requestCount, shownSuggestions == suggestions else { return }
        let candidates = PronunciationCandidate.candidates(from: suggestions, symbols: symbols)
        guard phase != .loaded(candidates) else { return }
        // Counts only, as when they were listed.
        Self.log.info("pronunciation suggestions checked again", [
            "candidates": candidates.count,
            "usable": candidates.count { $0.isUsable },
        ])
        phase = .loaded(candidates)
    }
}
