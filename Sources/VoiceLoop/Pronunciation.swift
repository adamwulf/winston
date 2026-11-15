import Foundation
import Logging
import LogSupport

/// A word and what to say in its place, for every voice: one of the pronunciations in settings.
public struct Pronunciation: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// The word as written. It matches only with the same case, and only as a whole word: "API"
    /// matches in "the API's docs", but not in "APIs" or "api". It can be several words.
    public var word: String
    /// What is said in its place.
    public var replacement: String

    public init(id: UUID = UUID(), word: String = "", replacement: String = "") {
        self.id = id
        self.word = word
        self.replacement = replacement
    }
}

/// Puts each pronunciation's replacement in place of its word.
struct PronunciationReplacer {
    private static let log = Logger(label: "voice.pronunciations")

    /// The replacement for each word.
    private let replacements: [String: String]
    /// Matches any of the words; nil when there are none.
    private let pattern: NSRegularExpression?

    /// Words and replacements are trimmed, and one left blank is skipped: it is still being
    /// typed. Of two with the same word, the first counts.
    init(_ pronunciations: [Pronunciation]) {
        var replacements: [String: String] = [:]
        for pronunciation in pronunciations {
            let word = pronunciation.word.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = pronunciation.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, !replacement.isEmpty, replacements[word] == nil else { continue }
            replacements[word] = replacement
        }
        self.replacements = replacements
        guard !replacements.isEmpty else {
            pattern = nil
            return
        }
        // Longest first, so "New York City" wins over "New York". Not after or before a letter
        // or digit, so only whole words match.
        let words = replacements.keys
            .sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        do {
            pattern = try NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])(?:"# + words + #")(?![\p{L}\p{N}])"#)
        } catch {
            // Every word is escaped, so this isn't expected. Codes only: the pattern holds them.
            Self.log.error("pronunciations pattern failed to compile; words are said as written", error.logCodes())
            pattern = nil
        }
    }

    /// `text` with each word replaced. A replacement is not itself looked through for words.
    func replaced(in text: String) -> String {
        guard let pattern else { return text }
        var result = text
        // From the end, so the ranges before each replacement stay where they were.
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result), let replacement = replacements[String(result[range])] else {
                continue
            }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}
