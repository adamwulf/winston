import Foundation
import Logging
import LogSupport

/// A word and how to say it: one of the pronunciations in settings. A respelling is said in place
/// of the word by every voice; phonemes are said by the Kokoro voices, and the system voices say
/// the word as written.
public struct Pronunciation: Codable, Hashable, Identifiable, Sendable {
    /// What `replacement` is.
    public enum Mode: String, Codable, Hashable, Sendable, CaseIterable {
        /// Text said in the word's place, by every voice: "JSON" said as "Jason".
        case respelling
        /// Kokoro phonemes for the word, said by the Kokoro voices only: "Kokoro" said as
        /// "kˈOkəɹO". They are in Kokoro's notation, IPA with a capital letter for each of five
        /// diphthongs (A for eɪ, I for aɪ, O for oʊ, W for aʊ, Y for ɔɪ) and the stress marks ˈ
        /// and ˌ. A symbol Kokoro doesn't have is dropped. The system voices say the word as
        /// written.
        case phonetic
    }

    public var id: UUID
    /// The word as written. It matches only with the same case, and only as a whole word: "API"
    /// matches in "the API's docs", but not in "APIs" or "api". It can be several words.
    public var word: String
    /// What is said in its place: text for a respelling, phonemes for a phonetic pronunciation.
    public var replacement: String
    public var mode: Mode

    public init(id: UUID = UUID(), word: String = "", replacement: String = "", mode: Mode = .respelling) {
        self.id = id
        self.word = word
        self.replacement = replacement
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case id, word, replacement, mode
    }

    /// One saved before there were phonetic pronunciations has no mode: it is a respelling.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        word = try container.decode(String.self, forKey: .word)
        replacement = try container.decode(String.self, forKey: .replacement)
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .respelling
    }
}

/// Puts each pronunciation's replacement in place of its word: a respelling's text, or a phonetic
/// pronunciation's placeholder (see `PhoneticPlaceholders`).
struct PronunciationReplacer {
    private static let log = Logger(label: "voice.pronunciations")

    /// What goes in place of each word.
    private let replacements: [String: String]
    /// Matches any of the words; nil when there are none.
    private let pattern: NSRegularExpression?

    /// Words and replacements are trimmed, and one left blank is skipped: it is still being
    /// typed. Of two with the same word, the first counts, whatever their modes. A phonetic
    /// pronunciation takes its placeholders from `placeholders`, and is skipped if it has none
    /// there.
    init(_ pronunciations: [Pronunciation], placeholders: PhoneticPlaceholders = PhoneticPlaceholders()) {
        var replacements: [String: String] = [:]
        for pronunciation in pronunciations {
            let word = pronunciation.word.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = pronunciation.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, !replacement.isEmpty, replacements[word] == nil else { continue }
            switch pronunciation.mode {
            case .respelling:
                replacements[word] = replacement
            case .phonetic:
                guard let text = placeholders.text(for: word, phonemes: replacement) else { continue }
                replacements[word] = text
            }
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

/// The made-up words that stand in for phonetic pronunciations' words in a message, and what they
/// stand for. KokoroTTS can be given phonemes for single lowercase words only, and can't forget
/// them, so the Kokoro voices are given each placeholder with its phonemes (`phonemes(in:)`), and
/// the system voices get the words back (`written(_:)`).
///
/// A word said with some phonemes has a placeholder for each of the phonemes' words, a space
/// between, so KokoroTTS can split a long sentence between them rather than inside one, where
/// it would guess at the pieces from their spelling. In a message the first starts with a capital
/// where the word does, since Kokoro's sentences are found by `NLTokenizer`, which reads a
/// lowercase word after a full stop as the same sentence going on. For the same reason, sentence
/// punctuation that ends the word (the "!" of "Yahoo!") stays in the message after them. A
/// placeholder is found whatever its case, and Kokoro looks words up in lowercase.
///
/// Placeholders are kept by word and phonemes, not by pronunciation, and never forgotten: a
/// message queued before its pronunciation was changed or removed still says the word it was
/// queued with, with the phonemes it had then, as a respelling's text is fixed once queued.
///
/// A placeholder is lowercase ASCII letters, a prefix no word has and a letter after them that
/// ends no contraction, so Kokoro's number and acronym rewriting and its phonemizer leave it
/// whole.
struct PhoneticPlaceholders: Sendable {
    /// A word said with some phonemes, both trimmed.
    private struct Key: Hashable {
        let word: String
        let phonemes: String
    }

    /// The placeholders of one word said with some phonemes.
    private struct Group {
        /// What a message holds in the word's place: the placeholders, a space between, the
        /// first with the word's capital if it starts with one, then the sentence punctuation the
        /// word ends with, if any.
        let text: String
        /// What a system voice says for the placeholders: the word without the sentence
        /// punctuation it ends with, which `text` keeps after them.
        let written: String
        /// The placeholders after the first, in order.
        let rest: [String]
    }

    /// Each word and phonemes' first placeholder.
    private var firstPlaceholders: [Key: String] = [:]
    /// Each group, by its first placeholder.
    private var groups: [String: Group] = [:]
    /// Each placeholder's phonemes: one of its group's phoneme words.
    private var phonemes: [String: String] = [:]

    /// What a message holds in place of `word` said with `phonemes`, once `add(word:phonemes:)`
    /// has given them placeholders.
    func text(for word: String, phonemes: String) -> String? {
        firstPlaceholders[Key(word: word, phonemes: phonemes)].flatMap { groups[$0]?.text }
    }

    /// Gives each phonetic pronunciation with a word and phonemes its placeholders, unless it has
    /// them.
    mutating func add(_ pronunciations: [Pronunciation]) {
        for pronunciation in pronunciations where pronunciation.mode == .phonetic {
            let word = pronunciation.word.trimmingCharacters(in: .whitespacesAndNewlines)
            let phonemes = pronunciation.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, !phonemes.isEmpty else { continue }
            add(word: word, phonemes: phonemes)
        }
    }

    /// Gives `word` said with `phonemes` placeholders, unless it has them, and returns what a
    /// message holds in its place. Both are trimmed and not empty.
    @discardableResult
    mutating func add(word: String, phonemes: String) -> String {
        let key = Key(word: word, phonemes: phonemes)
        if let first = firstPlaceholders[key], let group = groups[first] {
            return group.text
        }
        let phonemeWords = phonemes.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !phonemeWords.isEmpty else { return word }
        let placeholders = phonemeWords.indices.map { Self.placeholder(number: self.phonemes.count + $0) }
        for (placeholder, phonemeWord) in zip(placeholders, phonemeWords) {
            self.phonemes[placeholder] = phonemeWord
        }
        let punctuation = String(word.reversed().prefix(while: Self.endsSentence).reversed())
        var first = placeholders[0]
        if word.first?.isUppercase == true {
            first = first.prefix(1).uppercased() + first.dropFirst()
        }
        let group = Group(
            text: ([first] + placeholders.dropFirst()).joined(separator: " ") + punctuation,
            written: String(word.dropLast(punctuation.count)),
            rest: Array(placeholders.dropFirst())
        )
        firstPlaceholders[key] = placeholders[0]
        groups[placeholders[0]] = group
        return group.text
    }

    /// The phonemes of each placeholder in `text`, by placeholder in lowercase: what Kokoro needs
    /// to say it.
    func phonemes(in text: String) -> [String: String] {
        guard !phonemes.isEmpty else { return [:] }
        var found: [String: String] = [:]
        // A placeholder is a whole run of letters: a pronunciation's word matches only with no
        // letter or digit beside it.
        for match in text.matches(of: #/\p{L}+/#) {
            let placeholder = match.output.lowercased()
            if let phonemeWord = phonemes[placeholder] {
                found[placeholder] = phonemeWord
            }
        }
        return found
    }

    /// `text` with each group of placeholders back as its word, once, for the system voices. A
    /// placeholder away from the rest of its group, which a message never has, is left out rather
    /// than said.
    func written(_ text: String) -> String {
        guard !groups.isEmpty else { return text }
        // Words with a space between, so a group's placeholders are read together.
        return text.replacing(#/\p{L}+(?: \p{L}+)*/#) { match in
            var words: [String] = []
            // The placeholders still to come of the group being read.
            var expected: ArraySlice<String> = []
            for word in match.output.split(separator: " ") {
                let placeholder = word.lowercased()
                if expected.first == placeholder {
                    expected = expected.dropFirst()
                    continue
                }
                expected = []
                if let group = groups[placeholder] {
                    if !group.written.isEmpty {
                        words.append(group.written)
                    }
                    expected = group.rest[...]
                } else if phonemes[placeholder] == nil {
                    words.append(String(word))
                }
            }
            return words.joined(separator: " ")
        }
    }

    /// Whether `character` ends a sentence: what keeps a sentence of its own after a word.
    private static func endsSentence(_ character: Character) -> Bool {
        ".!?…‼⁇⁈⁉。！？".contains(character)
    }

    /// The placeholder numbered `number`, 0 or more: "zqx", the number in letters (a to z, then
    /// aa, ab and on), and "q". Kokoro's phonemizer expands a contraction written anywhere, even
    /// inside a word, so the last letter ends none ("he's", "it's", "can't"), and the first
    /// starts none.
    static func placeholder(number: Int) -> String {
        var letters = ""
        var rest = number
        repeat {
            letters.insert(Character(Unicode.Scalar(UInt8(ascii: "a") + UInt8(rest % 26))), at: letters.startIndex)
            rest = rest / 26 - 1
        } while rest >= 0
        return "zqx" + letters + "q"
    }
}
