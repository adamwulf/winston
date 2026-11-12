import Foundation

/// Decides when an utterance is finished: there is text, and it hasn't changed for
/// `pauseThreshold`. Pure: callers pass in the times, so it never reads a clock.
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

    /// True once there is non-empty text that hasn't changed for `pauseThreshold`.
    func isComplete(at now: Instant) -> Bool {
        guard let lastChange, !text.allSatisfy(\.isWhitespace) else { return false }
        return lastChange.duration(to: now) >= pauseThreshold
    }

    /// Forgets the current text, ready for the next utterance.
    mutating func reset() {
        text = ""
        lastChange = nil
    }
}
