import Foundation

/// Turns a bot message into text that sounds right when spoken.
public enum SpokenText {
    /// Drops fenced code blocks, strips leftover markdown symbols, turns `[text](url)` into
    /// "text", says bare URLs as "a link", and shortens long file paths.
    ///
    /// Heading, bullet and emphasis markers are removed but their words are kept, as are the
    /// contents of inline code. Absolute file paths become their last path component. Runs of
    /// spaces collapse to one, and blank lines are dropped; line breaks are kept so the
    /// synthesizer still pauses between lines.
    public static func speakable(_ text: String) -> String {
        var spokenLines: [String] = []
        var inFence = false
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if let fence = ["```", "~~~"].first(where: { trimmed.hasPrefix($0) }) {
                // A fence that opens and closes on one line is a whole code block by itself.
                let closesOnSameLine = !inFence && trimmed.count >= 2 * fence.count && trimmed.hasSuffix(fence)
                if !closesOnSameLine { inFence.toggle() }
                continue
            }
            if inFence { continue }
            let line = speakableLine(String(rawLine))
            if !line.isEmpty { spokenLines.append(line) }
        }
        return spokenLines.joined(separator: "\n")
    }

    private static func speakableLine(_ line: String) -> String {
        var result = line
        for rule in rules {
            result = rule.regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: rule.template
            )
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private struct Rule: Sendable {
        let regex: NSRegularExpression
        let template: String

        init(_ pattern: String, _ template: String) {
            // The patterns are fixed literals; a typo is a programmer error caught by the tests.
            regex = try! NSRegularExpression(pattern: pattern)
            self.template = template
        }
    }

    /// Applied in order to each line outside code fences.
    private static let rules: [Rule] = [
        // Heading and bullet markers at the start of a line.
        Rule(#"^\s*#{1,6}\s+"#, ""),
        Rule(#"^\s*[-*+]\s+"#, ""),
        // Inline code keeps its contents.
        Rule(#"`+([^`]+?)`+"#, "$1"),
        // [text](url) and ![alt](url) keep only the text.
        Rule(#"!?\[([^\]]*)\]\([^)\s]*\)"#, "$1"),
        // Bare URLs. The last character can't be sentence punctuation.
        Rule(#"\bhttps?://\S*[^\s.,;:!?'")\]>]"#, "a link"),
        // Absolute paths (at least two components, or starting with ~) become their last component.
        Rule(#"(?<![\w.~/:])(?:~(?:/[\w.@+-]+)*|(?:/[\w.@+-]+)+)/([\w.@+-]+)/?"#, "$1"),
        // Emphasis: **bold**, __bold__, *italic*, _italic_, ~~strike~~.
        Rule(#"\*\*(.+?)\*\*"#, "$1"),
        Rule(#"(?<!\w)__(.+?)__(?!\w)"#, "$1"),
        Rule(#"(?<![\w*])\*(?![\s*])(.+?)(?<![\s*])\*(?![\w*])"#, "$1"),
        Rule(#"(?<!\w)_(?![\s_])(.+?)(?<![\s_])_(?!\w)"#, "$1"),
        Rule(#"~~(.+?)~~"#, "$1"),
        // Leftover runs of whitespace.
        Rule(#"\s+"#, " "),
    ]
}
