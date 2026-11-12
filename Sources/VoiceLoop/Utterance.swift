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
    /// At most two alternates are included, and only ones that differ from `text` (and from
    /// each other) after trimming, ignoring case. Line breaks become spaces, so the message is
    /// always one line.
    public var messageText: String {
        let main = Self.singleLine(text)
        var seen: Set<String> = [main.lowercased()]
        var alternates: [String] = []
        for alternative in alternatives where alternates.count < 2 {
            let line = Self.singleLine(alternative)
            guard !line.isEmpty, seen.insert(line.lowercased()).inserted else { continue }
            alternates.append(line)
        }
        guard !alternates.isEmpty else { return "🎙️ " + main }
        return "🎙️ \(main) (alt: \(alternates.joined(separator: "; ")))"
    }

    /// Trims `text` and collapses every run of whitespace, including line breaks, to one space.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
