import Foundation
import Logging
import LogSupport
import NaturalLanguage

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
    /// The word as written. It matches only as a whole word: "API" matches in "the API's docs",
    /// but not in "APIs". It can be several words.
    public var word: String
    /// What is said in its place: text for a respelling, phonemes for a phonetic pronunciation.
    public var replacement: String
    public var mode: Mode
    /// Whether `word` matches only with the same case: "API" then matches "API" but not "api" or
    /// "Api". Otherwise it matches whatever its case: a respelling starts with a capital where the
    /// word it replaces does, and a system voice says a phonetic word it matched in another case
    /// as `word` has it.
    public var matchesCase: Bool

    public init(
        id: UUID = UUID(),
        word: String = "",
        replacement: String = "",
        mode: Mode = .respelling,
        matchesCase: Bool = true
    ) {
        self.id = id
        self.word = word
        self.replacement = replacement
        self.mode = mode
        self.matchesCase = matchesCase
    }

    private enum CodingKeys: String, CodingKey {
        case id, word, replacement, mode, matchesCase
    }

    /// One saved before there were phonetic pronunciations has no mode: it is a respelling. One
    /// saved before there was a choice of case matches only with the same case.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        word = try container.decode(String.self, forKey: .word)
        replacement = try container.decode(String.self, forKey: .replacement)
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .respelling
        matchesCase = try container.decodeIfPresent(Bool.self, forKey: .matchesCase) ?? true
    }
}

/// Puts each pronunciation's replacement in place of its word: a respelling's text, or a phonetic
/// pronunciation's placeholders (see `PhoneticPlaceholders`).
struct PronunciationReplacer {
    private static let log = Logger(label: "voice.pronunciations")

    /// What goes in place of a word.
    private enum Replacement {
        /// A respelling's text.
        case text(String)
        /// A phonetic pronunciation's placeholders: `plain`, which stand for all of the word,
        /// and for a word that ends with sentence punctuation, `keepingPunctuation`, which keep it
        /// after them for where it ends a sentence.
        case placeholders(plain: String, keepingPunctuation: String?)
    }

    /// What goes in place of each word that matches only with the same case.
    private let replacements: [String: Replacement]
    /// What goes in place of each word that matches whatever its case, by the word in lowercase.
    private let caselessReplacements: [String: Replacement]
    /// Matches any of the words; nil when there are none.
    private let pattern: NSRegularExpression?

    /// Words and replacements are trimmed, and one left blank is skipped: it is still being
    /// typed. Of two that match the same text, the first counts, whatever their modes: a word
    /// that matches whatever its case, after one with the same word in another case that matches
    /// only with it, still matches the other cases. A phonetic pronunciation takes its
    /// placeholders from `placeholders`, and is skipped if it has none there.
    init(_ pronunciations: [Pronunciation], placeholders: PhoneticPlaceholders = PhoneticPlaceholders()) {
        var replacements: [String: Replacement] = [:]
        var caselessReplacements: [String: Replacement] = [:]
        // Each word as `pattern` matches it, with its length.
        var alternatives: [(pattern: String, length: Int)] = []
        for pronunciation in pronunciations {
            let word = pronunciation.word.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = pronunciation.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = word.lowercased()
            guard !word.isEmpty, !replacement.isEmpty, caselessReplacements[lowercased] == nil,
                  !pronunciation.matchesCase || replacements[word] == nil else { continue }
            let value: Replacement
            switch pronunciation.mode {
            case .respelling:
                value = .text(replacement)
            case .phonetic:
                guard let plain = placeholders.text(for: word, phonemes: replacement, keepingPunctuation: false) else {
                    continue
                }
                let kept = placeholders.text(for: word, phonemes: replacement, keepingPunctuation: true)
                value = .placeholders(plain: plain, keepingPunctuation: kept == plain ? nil : kept)
            }
            let escaped = NSRegularExpression.escapedPattern(for: word)
            if pronunciation.matchesCase {
                replacements[word] = value
                alternatives.append((escaped, word.count))
            } else {
                caselessReplacements[lowercased] = value
                alternatives.append(("(?i:" + escaped + ")", word.count))
            }
        }
        self.replacements = replacements
        self.caselessReplacements = caselessReplacements
        guard !alternatives.isEmpty else {
            pattern = nil
            return
        }
        // Longest first, so "New York City" wins over "New York". Not after or before a letter
        // or digit, so only whole words match.
        let words = alternatives
            .sorted { $0.length > $1.length }
            .map(\.pattern)
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
    ///
    /// Placeholders never touch a letter or digit: a space goes between them and another
    /// replacement that would ("👏👏" said as two placeholders), or they would read as one word.
    /// A phonetic word's sentence punctuation ("Yahoo!") stays after its placeholders only where
    /// it ends a sentence in `text`, perhaps with closing quotes or brackets after it, so Kokoro's
    /// sentences end where they did; elsewhere ("Mr. Smith") the placeholders stand for all of
    /// the word, as a respelling does.
    func replaced(in text: String) -> String {
        guard let pattern else { return text }
        var result = ""
        // Whether `result` ends with a placeholder.
        var endsWithPlaceholder = false
        // Where `text`'s sentences end, as UTF-16 offsets, once a phonetic word needs them.
        var sentenceEnds: Set<Int>?

        func append(_ piece: some StringProtocol, isPlaceholders: Bool) {
            guard let first = piece.first else { return }
            if isPlaceholders || endsWithPlaceholder, let last = result.last,
               Self.isLetterOrDigit(last), Self.isLetterOrDigit(first) {
                result.append(" ")
            }
            result.append(contentsOf: piece)
            endsWithPlaceholder = isPlaceholders && piece.last.map(Self.isLetterOrDigit) == true
        }

        var cursor = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let word = String(text[range])
            let matchesCase = replacements[word] != nil
            guard let replacement = replacements[word] ?? caselessReplacements[word.lowercased()] else { continue }
            append(text[cursor..<range.lowerBound], isPlaceholders: false)
            switch replacement {
            case .text(var replacement):
                // A word that matches whatever its case may start a sentence in `text`, so its
                // respelling starts with a capital where the word does, or Kokoro would read
                // the two sentences as one. Its own capitals stay.
                if !matchesCase, word.first?.isUppercase == true {
                    replacement = replacement.prefix(1).uppercased() + replacement.dropFirst()
                }
                append(replacement, isPlaceholders: false)
            case .placeholders(let plain, let keepingPunctuation):
                var placeholders = plain
                if let keepingPunctuation {
                    let ends = sentenceEnds ?? Self.sentenceEnds(in: text)
                    sentenceEnds = ends
                    if Self.endsSentence(at: range.upperBound, in: text, sentenceEnds: ends) {
                        placeholders = keepingPunctuation
                    }
                }
                // The first starts with a capital where the word in `text` does, which for a
                // word that matches whatever its case isn't always where its pronunciation's does.
                let first = placeholders.prefix(1)
                placeholders = (word.first?.isUppercase == true ? first.uppercased() : first.lowercased())
                    + placeholders.dropFirst()
                append(placeholders, isPlaceholders: true)
            }
            cursor = range.upperBound
        }
        append(text[cursor...], isPlaceholders: false)
        return result
    }

    private static func isLetterOrDigit(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// Whether a sentence of `text` ends at `index`, or after nothing but closing quotes and
    /// brackets there: in `She shouted “Yahoo!” Then she left.`, the first sentence ends after
    /// the quote.
    private static func endsSentence(at index: String.Index, in text: String, sentenceEnds: Set<Int>) -> Bool {
        var index = index
        while true {
            if sentenceEnds.contains(index.utf16Offset(in: text)) {
                return true
            }
            guard index < text.endIndex, closes(text[index]) else {
                return false
            }
            index = text.index(after: index)
        }
    }

    /// Whether `character` closes a quote or a bracket: `”`, `’`, `»`, `)`, `]`, `}` and the
    /// like, or a straight quote, which after a word closes one.
    private static func closes(_ character: Character) -> Bool {
        if character == "\"" || character == "'" {
            return true
        }
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.properties.generalCategory {
        case .closePunctuation, .finalPunctuation:
            return true
        default:
            return false
        }
    }

    /// Where each of `text`'s sentences ends, without the spaces after it, as a UTF-16 offset:
    /// the sentences `NLTokenizer` finds, as Kokoro's are found.
    private static func sentenceEnds(in text: String) -> Set<Int> {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ends: Set<Int> = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range]
            let end = sentence.lastIndex { !$0.isWhitespace }.map(text.index(after:)) ?? range.lowerBound
            ends.insert(end.utf16Offset(in: text))
            return true
        }
        return ends
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
/// where the word in the message does, since Kokoro's sentences are found by `NLTokenizer`, which
/// reads a lowercase word after a full stop as the same sentence going on. For the same reason, a
/// word that ends with sentence punctuation (the "!" of "Yahoo!") has a second set of
/// placeholders, which keep it after them, for where it ends a sentence (see
/// `PronunciationReplacer`). `PronunciationReplacer` also sets the first's capital: a word that
/// matches whatever its case may be written otherwise than its pronunciation's. A placeholder is
/// found whatever its case, and Kokoro looks words up in lowercase.
///
/// Placeholders are kept by word and phonemes, not by pronunciation, and never forgotten: a
/// message queued before its pronunciation was changed or removed still says the word it was
/// queued with, with the phonemes it had then, as a respelling's text is fixed once queued.
///
/// A placeholder is lowercase ASCII letters, a prefix no word has and a letter after them that
/// ends no contraction, so Kokoro's number and acronym rewriting and its phonemizer leave it
/// whole.
struct PhoneticPlaceholders: Sendable {
    /// A word said with some phonemes, both trimmed, and whether its placeholders keep the
    /// sentence punctuation it ends with after them.
    private struct Key: Hashable {
        let word: String
        let phonemes: String
        let keepsPunctuation: Bool
    }

    /// What a message holds in place of each word said with some phonemes, as written: the
    /// placeholders, a space between, the first with the word's capital if it starts with one,
    /// and the sentence punctuation the word ends with, if they keep it. `PronunciationReplacer`
    /// gives the first the capital of the word in the message instead.
    private var texts: [Key: String] = [:]
    /// What a system voice says for each set of placeholders, by its first: the word, without the
    /// punctuation they keep, which follows them.
    private var writtenWords: [String: String] = [:]
    /// Each placeholder's phonemes: one of the phonemes' words.
    private var phonemes: [String: String] = [:]

    /// What a message holds in place of `word` said with `phonemes`, once `add(word:phonemes:)`
    /// has given them placeholders. `keepingPunctuation` puts the sentence punctuation the word
    /// ends with after the placeholders; a word that ends with none has the same text either way.
    func text(for word: String, phonemes: String, keepingPunctuation: Bool) -> String? {
        let keepsPunctuation = keepingPunctuation && !Self.sentencePunctuation(endingWith: word).isEmpty
        return texts[Key(word: word, phonemes: phonemes, keepsPunctuation: keepsPunctuation)]
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

    /// Gives `word` said with `phonemes` placeholders, unless it has them: a set that stands for
    /// all of it and, if it ends with sentence punctuation, a set that keeps that after them.
    /// Returns what a message that is just the word holds, ending its sentence. Both are trimmed
    /// and not empty.
    @discardableResult
    mutating func add(word: String, phonemes: String) -> String {
        let plain = add(Key(word: word, phonemes: phonemes, keepsPunctuation: false), punctuation: "")
        let punctuation = Self.sentencePunctuation(endingWith: word)
        guard !punctuation.isEmpty else { return plain }
        return add(Key(word: word, phonemes: phonemes, keepsPunctuation: true), punctuation: punctuation)
    }

    /// Gives `key` placeholders, unless it has them, and returns what a message holds in its
    /// place. `punctuation` is what it keeps after them.
    private mutating func add(_ key: Key, punctuation: String) -> String {
        if let text = texts[key] {
            return text
        }
        let phonemeWords = key.phonemes.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !phonemeWords.isEmpty else { return key.word }
        let placeholders = phonemeWords.indices.map { Self.placeholder(number: phonemes.count + $0) }
        for (placeholder, phonemeWord) in zip(placeholders, phonemeWords) {
            phonemes[placeholder] = phonemeWord
        }
        var first = placeholders[0]
        if key.word.first?.isUppercase == true {
            first = first.prefix(1).uppercased() + first.dropFirst()
        }
        let text = ([first] + placeholders.dropFirst()).joined(separator: " ") + punctuation
        texts[key] = text
        writtenWords[placeholders[0]] = String(key.word.dropLast(punctuation.count))
        return text
    }

    /// The phonemes of each placeholder in `text`, by placeholder in lowercase: what Kokoro needs
    /// to say it.
    func phonemes(in text: String) -> [String: String] {
        guard !phonemes.isEmpty else { return [:] }
        var found: [String: String] = [:]
        // A placeholder is a whole run of letters: no letter or digit ever touches one.
        for match in text.matches(of: #/\p{L}+/#) {
            let placeholder = match.output.lowercased()
            if let phonemeWord = phonemes[placeholder] {
                found[placeholder] = phonemeWord
            }
        }
        return found
    }

    /// `text` with each set of placeholders back as its word, once, for the system voices. The
    /// placeholders after a set's first are left out: its word is said for the first.
    func written(_ text: String) -> String {
        guard !writtenWords.isEmpty else { return text }
        // Words with a space between, so the space before a placeholder left out goes with it.
        return text.replacing(#/\p{L}+(?: \p{L}+)*/#) { match in
            match.output.split(separator: " ")
                .compactMap { word -> String? in
                    let placeholder = word.lowercased()
                    if let written = writtenWords[placeholder] {
                        return written.isEmpty ? nil : written
                    }
                    return phonemes[placeholder] == nil ? String(word) : nil
                }
                .joined(separator: " ")
        }
    }

    /// The sentence punctuation `word` ends with ("!" for "Yahoo!", "!?" for "What!?"), if any.
    private static func sentencePunctuation(endingWith word: String) -> String {
        String(word.reversed().prefix { ".!?…‼⁇⁈⁉。！？".contains($0) }.reversed())
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
