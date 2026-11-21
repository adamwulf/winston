import Foundation
import Logging
import LogSupport
import Observation
import VoiceLoop

/// The suggested pronunciations of one word, for the list the Suggest button on an IPA
/// pronunciation opens in settings: loading, then the suggestions, or why there are none.
/// `start()` asks as the list shows, `generate()` asks again, for Regenerate, and `cancel()` stops
/// the request as the list closes. A suggester that can't run now isn't asked: the list says why
/// at once. One that doesn't answer within its timeout is given up on, and the list says so,
/// rather than load for good. The suggestions are kept as the suggester gave them (trimmed,
/// without repeats); `candidates` checks them against the symbols Kokoro has each time it is read,
/// so a suggestion the fallback symbols lacked can be used once the Kokoro model is ready, with
/// nothing asked again. Made by `AppModel.pronunciationSuggestions(for:)`.
///
/// Each step is logged under `app.suggestions` at notice level, with the request's number and the
/// time since it started (`ms`): counts and codes only, never the word or the suggestions.
@MainActor
@Observable
public final class PronunciationSuggestions: Identifiable {
    private static let log = Logger(label: "app.suggestions")

    /// How long a request may take before the list gives up on it. The on-device model answers in
    /// 2 to 4 s on a Mac.
    static let defaultTimeout: Duration = .seconds(60)

    /// Where the latest request is.
    public enum Phase: Equatable, Sendable {
        /// Waiting for the suggester, or about to ask it.
        case loading
        /// The suggester's suggestions as settings lists them (see
        /// `PronunciationSuggestion.listed(_:)`), perhaps none.
        case loaded([PronunciationSuggestion])
        /// The suggester can't run, failed, or didn't answer in time: what to tell the user.
        case failed(String)
    }

    /// The word, trimmed.
    public let word: String
    public private(set) var phase: Phase = .loading
    /// Where the suggestions come from, for the list's footer: the suggester's own words.
    public var attribution: String { suggester.attribution }
    @ObservationIgnored private let suggester: any PronunciationSuggester
    /// How long a request may take before the list gives up on it.
    @ObservationIgnored private let timeout: Duration
    /// The phoneme symbols Kokoro has now: for `AppModel`'s, `VoiceLoop.kokoroPhonemeSymbols`,
    /// which is observable, so a view showing `candidates` follows it.
    @ObservationIgnored private let symbols: @MainActor () -> Set<Character>
    /// Told each time a request's answer has been handled, shown or dropped. Nothing in the app;
    /// tests can't otherwise see that an answer was dropped.
    @ObservationIgnored private let answerHandled: @MainActor () -> Void
    /// The latest request, until it is answered, replaced, cancelled or given up on.
    @ObservationIgnored private var request: Task<Void, Never>?
    /// Gives up on the latest request once the timeout has passed.
    @ObservationIgnored private var deadline: Task<Void, Never>?
    /// Numbers the requests, from 1, for the logs and to tell their answers apart.
    @ObservationIgnored private var requestCount = 0
    /// The request whose answer the list shows when it comes; nil when there is none, so an
    /// answer to a request replaced, cancelled or given up on is dropped.
    @ObservationIgnored private var awaitedRequest: Int?
    /// When the latest request started, for the logs.
    @ObservationIgnored private var requestStarted = ContinuousClock.now

    init(
        word: String,
        suggester: any PronunciationSuggester,
        timeout: Duration = defaultTimeout,
        symbols: @escaping @MainActor () -> Set<Character>,
        answerHandled: @escaping @MainActor () -> Void = {}
    ) {
        self.word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        self.suggester = suggester
        self.timeout = timeout
        self.symbols = symbols
        self.answerHandled = answerHandled
        // Lengths only: the word is the user's.
        Self.log.notice("pronunciation suggestions opened", ["wordChars": self.word.count])
    }

    /// The suggestions loaded, each checked against the symbols Kokoro has now; none while
    /// loading or after a failure.
    public var candidates: [PronunciationCandidate] {
        guard case .loaded(let suggestions) = phase else { return [] }
        let symbols = symbols()
        return suggestions.map { PronunciationCandidate($0, symbols: symbols) }
    }

    /// Asks for the suggestions as the list shows, unless a request is under way or has been
    /// answered. The list's content can show more than once: on the iPhone, its popover becomes a
    /// sheet.
    public func start() {
        let asks = phase == .loading && awaitedRequest == nil
        Self.log.notice("pronunciation suggestions shown", [
            "asks": asks,
            "latestRequest": requestCount,
        ])
        if asks {
            generate()
        }
    }

    /// Asks the suggester for the word's pronunciations, replacing any request under way: the
    /// first time, and for Regenerate. Loading until it answers, or until the timeout.
    public func generate() {
        let replaced = awaitedRequest
        stopRequest()
        requestCount += 1
        let number = requestCount
        requestStarted = .now
        let started = requestStarted
        let availability = suggester.availability
        var fields: [String: CustomStringConvertible] = [
            "request": number,
            "availability": availability.logName,
        ]
        if let replaced {
            fields["replacedRequest"] = replaced
        }
        Self.log.notice("pronunciation suggestions requested", fields)
        if case .unavailable(let reason) = availability {
            // It would only fail: the list says why, and what would let it run.
            phase = .failed(userMessage(for: PronunciationSuggestionError.unavailable(reason)))
            return
        }
        awaitedRequest = number
        phase = .loading
        request = Task { [word, suggester] in
            let result: Result<[PronunciationSuggestion], any Error>
            do {
                result = .success(try await suggester.suggestions(for: word))
            } catch {
                result = .failure(error)
            }
            defer { self.answerHandled() }
            self.answer(result, toRequest: number, started: started)
        }
        deadline = Task { [timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self.giveUp(onRequest: number, started: started)
        }
    }

    /// Stops the request under way, as the list closes.
    public func cancel() {
        if let awaitedRequest {
            Self.log.notice("pronunciation suggestions cancelled", [
                "request": awaitedRequest,
                "ms": Self.milliseconds(since: requestStarted),
            ])
        }
        stopRequest()
    }

    /// Shows `result`, the answer to request `number`, if the list still awaits it; drops it
    /// otherwise.
    private func answer(_ result: Result<[PronunciationSuggestion], any Error>, toRequest number: Int, started: ContinuousClock.Instant) {
        guard number == awaitedRequest else {
            Self.log.notice("pronunciation suggestions answer dropped", [
                "request": number,
                "latestRequest": requestCount,
                "ms": Self.milliseconds(since: started),
            ])
            return
        }
        awaitedRequest = nil
        request = nil
        deadline?.cancel()
        deadline = nil
        switch result {
        case .success(let suggestions):
            let listed = PronunciationSuggestion.listed(suggestions)
            phase = .loaded(listed)
            // Counts only: the word and the phonemes are the user's.
            Self.log.notice("pronunciation suggestions listed", [
                "request": number,
                "suggestions": suggestions.count,
                "listed": listed.count,
                "usable": candidates.count { $0.isUsable },
                "ms": Self.milliseconds(since: started),
            ])
        case .failure(let error):
            // Codes only: a suggester's error can quote the word.
            Self.log.warning("pronunciation suggestions failed", error.logCodes([
                "request": String(number),
                "reason": (error as? PronunciationSuggestionError)?.logName ?? "other",
                "ms": String(Self.milliseconds(since: started)),
            ]))
            phase = .failed(userMessage(for: error))
        }
    }

    /// Gives up on request `number` once the timeout has passed, if the list still awaits it: the
    /// request is cancelled, its answer will be dropped, and the list says why.
    private func giveUp(onRequest number: Int, started: ContinuousClock.Instant) {
        guard number == awaitedRequest else { return }
        Self.log.warning("pronunciation suggestions timed out", [
            "request": number,
            "timeoutMs": Int(timeout / .milliseconds(1)),
            "ms": Self.milliseconds(since: started),
        ])
        stopRequest()
        phase = .failed(userMessage(for: PronunciationSuggestionError.timedOut))
    }

    /// Cancels the request under way and its deadline. Its answer, if it still comes, is dropped.
    private func stopRequest() {
        request?.cancel()
        request = nil
        deadline?.cancel()
        deadline = nil
        awaitedRequest = nil
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int(start.duration(to: .now) / .milliseconds(1))
    }
}
