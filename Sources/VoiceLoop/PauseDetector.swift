import Foundation

/// Decides when an utterance is finished: there is text, and it hasn't changed for
/// `pauseThreshold`. Text that doesn't end a sentence (no closing `.`, `?` or `!`, as in
/// "but it's uh") waits twice as long, so a mid-thought pause doesn't split the message; the
/// transcriber adds the closing punctuation once the speaker has finished. Pure: callers pass
/// in the times, so it never reads a clock.
struct PauseDetector {
    typealias Instant = ContinuousClock.Instant

    var pauseThreshold: Duration
    /// The latest transcript passed to `update(text:at:)`.
    private(set) var text = ""
    private var lastChange: Instant?

    init(pauseThreshold: Duration) {
        self.pauseThreshold = pauseThreshold
    }

    /// Records the transcript at `time`. The pause clock restarts only when the text differs.
    mutating func update(text newText: String, at time: Instant) {
        guard newText != text else { return }
        text = newText
        lastChange = time
    }

    /// True once there is non-empty text that hasn't changed for `pauseThreshold`, or twice
    /// that when the text doesn't end a sentence.
    func isComplete(at now: Instant) -> Bool {
        guard let lastChange, !text.allSatisfy(\.isWhitespace) else { return false }
        let threshold = Self.endsSentence(text) ? pauseThreshold : pauseThreshold * 2
        return lastChange.duration(to: now) >= threshold
    }

    /// Whether `text` ends with sentence-final punctuation, ignoring closing quotes and brackets.
    static func endsSentence(_ text: String) -> Bool {
        let trailing = text.reversed().first { !$0.isWhitespace && !"\"')]”’".contains($0) }
        return trailing.map { ".?!…".contains($0) } ?? false
    }

    /// Forgets the current text, ready for the next utterance.
    mutating func reset() {
        text = ""
        lastChange = nil
    }
}
