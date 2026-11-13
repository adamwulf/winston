import Foundation

/// One finished spoken message: what was heard, plus the recognizer's other readings.
public struct Utterance: Sendable, Equatable {
    /// The most likely transcription.
    public var text: String
    /// Other readings of phrases that differ from `text`, most likely first. At most two are used.
    public var alternatives: [String]

    public init(text: String, alternatives: [String] = []) {
        self.text = text
        self.alternatives = alternatives
    }

    /// The Telegram message body: `🎙️ <text>`, plus ` (alt: …)` when the recognizer
    /// heard something different. Always a single message.
    ///
    /// At most two alternates are included, and only ones whose words differ from `text` (and
    /// from each other), ignoring case, punctuation and filler words. Line breaks become
    /// spaces, so the message is always one line.
    public var messageText: String {
        let main = Self.singleLine(text)
        var seen: Set<[String]> = [Self.words(of: main)]
        var alternates: [String] = []
        for alternative in alternatives where alternates.count < 2 {
            let line = Self.singleLine(alternative)
            guard !line.isEmpty, seen.insert(Self.words(of: line)).inserted else { continue }
            alternates.append(line)
        }
        guard !alternates.isEmpty else { return "🎙️ " + main }
        return "🎙️ \(main) (alt: \(alternates.joined(separator: "; ")))"
    }

    /// Trims `text` and collapses every run of whitespace, including line breaks, to one space.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The words of `text`, lowercased, without punctuation or filler words like "uh".
    static func words(of text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" })
            .map(String.init)
            .filter { !fillers.contains($0) }
    }

    /// Whether `alternative` is another reading of the same words as `text`: the same number
    /// of words, with at least one different (like "mark that read" for "mark that red").
    /// Readings that only change punctuation, fillers or case, or that cover fewer or more
    /// words, aren't worth sending.
    static func isRereading(_ alternative: String, of text: String) -> Bool {
        let alternativeWords = words(of: alternative)
        let textWords = words(of: text)
        return !alternativeWords.isEmpty && alternativeWords.count == textWords.count && alternativeWords != textWords
    }

    private static let fillers: Set<String> = ["uh", "um", "er", "ah", "hmm", "mm"]
}
