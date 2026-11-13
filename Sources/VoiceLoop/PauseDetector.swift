import Foundation

/// Decides when an utterance is finished: there is text, and the speaker has been quiet for
/// `pauseThreshold`. Quiet means neither the transcript changed nor the microphone heard
/// voice (`heardVoice(at:)`); the transcript alone lags speech by more than a second at
/// times, which used to send a paragraph one sentence at a time.
///
/// Text that doesn't end a sentence (no closing `.`, `?` or `!`, as in "but it's uh") waits
/// twice as long, so a mid-thought pause doesn't split the message; the transcriber adds the
/// closing punctuation once the speaker has finished. Pure: callers pass in the times, so it
/// never reads a clock.
struct PauseDetector {
    typealias Instant = ContinuousClock.Instant

    var pauseThreshold: Duration
    /// The latest transcript passed to `update(text:at:)`.
    private(set) var text = ""
    private var lastChange: Instant?
    private var lastVoice: Instant?

    init(pauseThreshold: Duration) {
        self.pauseThreshold = pauseThreshold
    }

    /// Records the transcript at `time`. The pause clock restarts only when the text differs.
    mutating func update(text newText: String, at time: Instant) {
        guard newText != text else { return }
        text = newText
        lastChange = time
    }

    /// Records that the microphone heard voice at `time`, which restarts the pause clock.
    mutating func heardVoice(at time: Instant) {
        lastVoice = time
    }

    /// True once there is non-empty text and the speaker has been quiet for `pauseThreshold`,
    /// or twice that when the text doesn't end a sentence. Voice that never goes quiet (a TV,
    /// a noisy room) can't hold a message forever: after `pauseThreshold` four times over
    /// without a transcript change, it completes anyway.
    func isComplete(at now: Instant) -> Bool {
        guard let lastChange, !text.allSatisfy(\.isWhitespace) else { return false }
        let threshold = Self.endsSentence(text) ? pauseThreshold : pauseThreshold * 2
        let lastActivity = max(lastChange, lastVoice ?? lastChange)
        return lastActivity.duration(to: now) >= threshold
            || lastChange.duration(to: now) >= pauseThreshold * 4
    }

    /// Whether `text` ends with sentence-final punctuation, ignoring closing quotes and brackets.
    static func endsSentence(_ text: String) -> Bool {
        let trailing = text.reversed().first { !$0.isWhitespace && !"\"')]”’".contains($0) }
        return trailing.map { ".?!…".contains($0) } ?? false
    }

    /// Forgets the current text and voice, ready for the next utterance.
    mutating func reset() {
        text = ""
        lastChange = nil
        lastVoice = nil
    }
}
