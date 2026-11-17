/// Tells a reply's own words, heard back through the microphone, from Adam's.
///
/// Echo cancellation doesn't always take all of a reply out of what the microphone hears: on the
/// iPhone's speaker the start of a reply can leak through loudly enough for the recognizer to
/// report its words (docs/research/echo-cancellation-regression.md). Echo is a stretch of the
/// reply, in order, and usually recognized clearly, so heard text of `n` words is echo when at
/// least two thirds of them, rounded up, line up with `n + 2` consecutive words of the reply:
/// the longest common subsequence, word for word, with the stretch of the reply that fits best.
/// So one heard word must be one of the reply's words, and two must both be there, in order,
/// within four words of the reply. Words the reply has far apart don't add up, which keeps a short interruption
/// such as "hold on" from counting as echo because the reply says "on" somewhere. Empty text
/// never is echo. Words are compared as `Utterance.words(of:)` gives them: lowercased, without
/// punctuation, apostrophes or filler words.
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
        let required = (2 * heardWords.count + 2) / 3
        // The heard words with room for two the recognizer missed.
        let width = min(heardWords.count + 2, replyWords.count)
        guard width > 0 else { return false }
        for start in 0...(replyWords.count - width) {
            let stretch = replyWords[start..<(start + width)]
            if Self.alignedCount(heardWords, stretch) >= required {
                return true
            }
        }
        return false
    }

    /// The length of the longest common subsequence of `heard` and `stretch`.
    private static func alignedCount(_ heard: [String], _ stretch: ArraySlice<String>) -> Int {
        // One row of the usual table at a time: `previous[j]` aligns the heard words so far
        // with the first `j` words of the stretch.
        var previous = [Int](repeating: 0, count: stretch.count + 1)
        var current = previous
        for word in heard {
            for (index, replyWord) in stretch.enumerated() {
                current[index + 1] = word == replyWord
                    ? previous[index] + 1
                    : max(previous[index + 1], current[index])
            }
            swap(&previous, &current)
        }
        return previous[stretch.count]
    }
}
