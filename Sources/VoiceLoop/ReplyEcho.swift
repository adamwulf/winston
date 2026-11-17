/// Tells a reply's own words, heard back through the microphone, from Adam's.
///
/// Echo cancellation doesn't always take all of a reply out of what the microphone hears: on the
/// iPhone's speaker the start of a reply can leak through loudly enough for the recognizer to
/// report its words (docs/research/echo-cancellation-regression.md). Heard text is the reply's
/// echo when at least half of its words line up with the reply's words in order (their longest
/// common subsequence, word for word). A single heard word is echo only if it is one of the
/// reply's words, and empty text never is. Words are compared as `Utterance.words(of:)` gives
/// them: lowercased, without punctuation, apostrophes or filler words.
struct ReplyEcho: Sendable {
    private let replyWords: [String]

    /// `reply` as it is spoken: the text after markdown stripping and pronunciations.
    init(reply: String) {
        replyWords = Utterance.words(of: reply)
    }

    /// Whether any of `readings` is echo: a result's text and its alternatives, say. A misheard
    /// word often has the right one among the alternatives ("Hi" for "Hey").
    func isEcho(anyOf readings: [String]) -> Bool {
        readings.contains { isEcho($0) }
    }

    /// Whether `heard` is echo of the reply.
    func isEcho(_ heard: String) -> Bool {
        let heardWords = Utterance.words(of: heard)
        guard !heardWords.isEmpty else { return false }
        return 2 * Self.alignedCount(heardWords, replyWords) >= heardWords.count
    }

    /// The length of the longest common subsequence of `heard` and `reply`.
    private static func alignedCount(_ heard: [String], _ reply: [String]) -> Int {
        // One row of the usual table at a time: `previous[j]` aligns the heard words so far
        // with the first `j` reply words.
        var previous = [Int](repeating: 0, count: reply.count + 1)
        var current = previous
        for word in heard {
            for (index, replyWord) in reply.enumerated() {
                current[index + 1] = word == replyWord
                    ? previous[index] + 1
                    : max(previous[index + 1], current[index])
            }
            swap(&previous, &current)
        }
        return previous[reply.count]
    }
}
