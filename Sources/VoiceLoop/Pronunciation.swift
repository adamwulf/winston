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
    /// pronunciation takes its placeholder from `placeholders`, and is skipped if it has none
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
                guard let placeholder = placeholders.placeholder(for: pronunciation.id) else { continue }
                replacements[word] = placeholder
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

/// The made-up words that stand in for phonetic pronunciations' words in a message, and the word
/// and phonemes each stands for. KokoroTTS can be given phonemes for single lowercase words only,
/// and can't forget them, so the Kokoro voices are given each placeholder with its phonemes
/// (`phonemes(in:)`), and the system voices get the words back (`written(_:)`).
///
/// A placeholder is lowercase ASCII letters, a prefix no word has and a letter after them that
/// ends no contraction, so Kokoro's number and acronym rewriting and its phonemizer leave it
/// whole. Each phonetic pronunciation keeps its placeholder for the run, and a placeholder is
/// never forgotten: a message queued before its pronunciation was changed or removed still says
/// the word, with the pronunciation's latest phonemes.
struct PhoneticPlaceholders: Sendable {
    /// Stands in for the word of `VoiceLoop.preview(word:phonemes:)`, whose word and phonemes
    /// are the latest preview's.
    static let preview = placeholder(number: 0)

    /// Each phonetic pronunciation's placeholder, by its id.
    private var placeholders: [UUID: String] = [:]
    /// The word and phonemes each placeholder stands for, trimmed.
    private var entries: [String: (word: String, phonemes: String)] = [:]

    /// The placeholder of the phonetic pronunciation with `id`, if it has a word and phonemes.
    func placeholder(for id: UUID) -> String? {
        placeholders[id]
    }

    /// Gives each phonetic pronunciation with a word and phonemes a placeholder, if it has none
    /// yet, and records its word and phonemes as they are now.
    mutating func update(with pronunciations: [Pronunciation]) {
        for pronunciation in pronunciations where pronunciation.mode == .phonetic {
            let word = pronunciation.word.trimmingCharacters(in: .whitespacesAndNewlines)
            let phonemes = pronunciation.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, !phonemes.isEmpty else { continue }
            let placeholder = placeholders[pronunciation.id] ?? Self.placeholder(number: placeholders.count + 1)
            placeholders[pronunciation.id] = placeholder
            entries[placeholder] = (word, phonemes)
        }
    }

    /// Makes `preview` stand for `word` said with `phonemes`.
    mutating func setPreview(word: String, phonemes: String) {
        entries[Self.preview] = (word, phonemes)
    }

    /// The phonemes of each placeholder in `text`, by placeholder: what Kokoro needs to say it.
    func phonemes(in text: String) -> [String: String] {
        guard !entries.isEmpty else { return [:] }
        var phonemes: [String: String] = [:]
        // A placeholder is a whole run of letters: a pronunciation's word matches only with no
        // letter or digit beside it.
        for match in text.matches(of: #/\p{L}+/#) {
            let word = String(match.output)
            if let entry = entries[word] {
                phonemes[word] = entry.phonemes
            }
        }
        return phonemes
    }

    /// `text` with each placeholder back as its word, for the system voices.
    func written(_ text: String) -> String {
        guard !entries.isEmpty else { return text }
        return text.replacing(#/\p{L}+/#) { match in
            entries[String(match.output)]?.word ?? String(match.output)
        }
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
