import Foundation

/// How Speak IPA readies a message for the on-device model: as plain words (`normalized(_:)`), in
/// chunks small enough for its context window and quick enough that the first can play soon
/// (`chunks(in:)`), each cut into words and what lies between them (`segments(of:)`), so the
/// model's IPA for each word can take that word's place and the punctuation stays the message's.
public enum SpeakIPAText {
    /// The most characters the first chunk has: it is all the model transcribes before the first
    /// sound, about 2 s on a Mac for 14 words.
    public static let firstChunkLimit = 80
    /// The most characters any later chunk has. The model writes about 14 tokens a word (the word,
    /// its IPA, and the structure around them), so even on a 4,096-token context this leaves
    /// plenty of room, and a chunk is written about as fast as it is said.
    public static let chunkLimit = 240

    /// `text` as words for the model to transcribe, one line per line of the message: markdown and
    /// code blocks dropped and links said as their text or "a link" (`SpokenText.speakable(_:)`),
    /// emoji left out, a few abbreviations written out, numbers as words (`KokoroNumbers`), and
    /// a hyphen, slash or underscore between letters said as a space ("well-known" is "well
    /// known"), since KokoroTTS glues the words around one together. A line that doesn't end in
    /// punctuation (a list item, a heading) ends with a full stop, so it is said as a sentence.
    public static func normalized(_ text: String) -> String {
        let numbers = KokoroNumbers()
        return SpokenText.speakable(text)
            .split(whereSeparator: \.isNewline)
            .map { line in
                var line = withoutEmoji(String(line))
                line = abbreviationsWrittenOut(line)
                line = numbers.spelledOut(line)
                line = replacing(joinerBetweenLetters, in: line, with: " ")
                line = line.replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, line.contains(where: { $0.isLetter }) else { return "" }
                return endsSentence(line) ? line : line + "."
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// `normalized`, the text `normalized(_:)` gives, in chunks to transcribe one at a time, in
    /// order: whole sentences where they fit, the first chunk at most `firstChunkLimit` characters
    /// and the others at most `chunkLimit`. A sentence too long for a chunk is cut after a comma,
    /// semicolon, colon or dash where it can be, and between words where it can't; the rest of a
    /// first sentence cut to fit the first chunk starts the second. A single word longer than a
    /// chunk is a chunk of its own.
    public static func chunks(
        in normalized: String,
        firstChunkLimit: Int = firstChunkLimit,
        chunkLimit: Int = chunkLimit
    ) -> [String] {
        var pieces = KokoroText.sentences(in: normalized).flatMap { pieces(of: $0, limit: chunkLimit) }
        if let first = pieces.first, first.count > firstChunkLimit {
            pieces.replaceSubrange(0...0, with: Self.pieces(of: first, limit: firstChunkLimit))
        }
        var chunks: [String] = []
        var current = ""
        for piece in pieces {
            let limit = chunks.isEmpty ? firstChunkLimit : chunkLimit
            if current.isEmpty {
                current = piece
            } else if current.count + 1 + piece.count <= limit {
                current += " " + piece
            } else {
                chunks.append(current)
                current = piece
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    /// One part of a chunk: a word, or what comes between two words.
    public enum Segment: Hashable, Sendable {
        /// Letters, digits and the apostrophes inside them: "don't", "Joaquín".
        case word(String)
        /// Spaces and punctuation.
        case other(String)
    }

    /// `chunk` as words and what lies between them, in order; together they are `chunk`.
    public static func segments(of chunk: String) -> [Segment] {
        var segments: [Segment] = []
        var current = ""
        var inWord = false
        let characters = Array(chunk)
        for (index, character) in characters.enumerated() {
            // An apostrophe between two letters is part of the word: "don't".
            let isApostropheInWord = isApostrophe(character) && inWord
                && index + 1 < characters.count && isWordCharacter(characters[index + 1])
            let isWord = isWordCharacter(character) || isApostropheInWord
            if isWord != inWord, !current.isEmpty {
                segments.append(inWord ? .word(current) : .other(current))
                current = ""
            }
            inWord = isWord
            current.append(character)
        }
        if !current.isEmpty {
            segments.append(inWord ? .word(current) : .other(current))
        }
        return segments
    }

    /// The words of `chunk`, in order: its `.word` segments.
    public static func words(of chunk: String) -> [String] {
        segments(of: chunk).compactMap { segment in
            if case .word(let word) = segment { return word }
            return nil
        }
    }

    // MARK: - The model's IPA

    /// A chunk as Speak IPA says it, made from the model's words (`speech(of:transcribed:symbols:)`),
    /// with counts for the logs.
    public struct ChunkSpeech: Equatable, Sendable {
        /// The chunk's parts, in order: each word with IPA Kokoro can say as its phonemes, and
        /// everything else (punctuation, spaces, words without usable IPA) as written.
        public let parts: [IPASpeechPart]
        /// The chunk's words.
        public let words: Int
        /// The entries the model wrote.
        public let generated: Int
        /// Words said with the model's IPA.
        public let wordsWithIPA: Int
        /// Words the model gave no IPA for: it left them out, or wrote another word in their place.
        public let unmatchedWords: Int
        /// Words whose IPA, converted to Kokoro's notation, has a symbol Kokoro doesn't have.
        public let unknownSymbolWords: Int
        /// Words whose IPA converted to nothing.
        public let emptyWords: Int
        /// Words whose "IPA" was the word itself, as written.
        public let echoedWords: Int

        /// Whether at least half the chunk's words have IPA Kokoro can say. Speak IPA says a chunk
        /// that doesn't as written instead: the model's answer has gone wrong.
        public var usesIPA: Bool {
            words > 0 && wordsWithIPA * 2 >= words
        }
    }

    /// `chunk` with the model's IPA in place of its words. Each of the model's words is matched to
    /// the chunk's in order, whatever their case, accents or apostrophes; a word the model split
    /// in two or three ("itsy bitsy" for "itsybitsy") gets their IPA as one word, and words it
    /// joined into one get its IPA's words, if it has as many. A word the model added is skipped,
    /// and one it left out is said as written, as long as the two get back in step within three
    /// words; past that, each word is matched to the model's word in its place, only if they are
    /// the same.
    ///
    /// Each matched word's IPA, without any parentheses, is converted to Kokoro's notation as one
    /// word (`MisakiPhonemes.fromIPA(_:asOneWord:)`). It is said as written instead if that is
    /// empty, if it has a symbol not in `symbols` (the ones Kokoro has, `VoiceLoop.kokoroPhonemeSymbols`),
    /// or if the "IPA" is just the word, which the conversion would otherwise read letter by letter.
    public static func speech(of chunk: String, transcribed: [TranscribedWord], symbols: Set<Character>) -> ChunkSpeech {
        let words = words(of: chunk)
        let ipa = matchedIPA(words: words, transcribed: transcribed)
        var phonemes: [Int: String] = [:]
        var unknownSymbolWords = 0
        var emptyWords = 0
        var echoedWords = 0
        for (index, wordIPA) in ipa {
            let cleaned = wordIPA.filter { $0 != "(" && $0 != ")" }
            let converted = MisakiPhonemes.fromIPA(cleaned, asOneWord: true)
            if converted.isEmpty {
                emptyWords += 1
            } else if key(cleaned) == key(words[index]) {
                echoedWords += 1
            } else if !MisakiPhonemes.unknownSymbols(in: converted, symbols: symbols).isEmpty {
                unknownSymbolWords += 1
            } else {
                phonemes[index] = converted
            }
        }
        var parts: [IPASpeechPart] = []
        var wordIndex = 0
        for segment in segments(of: chunk) {
            switch segment {
            case .other(let text):
                parts.append(.text(text))
            case .word(let word):
                parts.append(phonemes[wordIndex].map { .phonemes(word: word, phonemes: $0) } ?? .text(word))
                wordIndex += 1
            }
        }
        return ChunkSpeech(
            parts: parts,
            words: words.count,
            generated: transcribed.count,
            wordsWithIPA: phonemes.count,
            unmatchedWords: words.count - ipa.count,
            unknownSymbolWords: unknownSymbolWords,
            emptyWords: emptyWords,
            echoedWords: echoedWords
        )
    }

    /// The IPA the model wrote for each of `words` it matches, by the word's index: see
    /// `speech(of:transcribed:symbols:)`.
    private static func matchedIPA(words: [String], transcribed: [TranscribedWord]) -> [Int: String] {
        let wordKeys = words.map(key)
        let generatedKeys = transcribed.map { key($0.word) }
        var ipa: [Int: String] = [:]
        var i = 0
        var j = 0
        // How far ahead to look for the two to get back in step.
        let lookahead = 3
        while i < words.count, j < transcribed.count {
            // Nothing to match on: punctuation the model wrote as a word, say.
            if wordKeys[i].isEmpty {
                i += 1
                continue
            }
            if generatedKeys[j].isEmpty {
                j += 1
                continue
            }
            if wordKeys[i] == generatedKeys[j] {
                ipa[i] = transcribed[j].ipa
                i += 1
                j += 1
                continue
            }
            // The model split the word.
            if let count = (2...lookahead).first(where: {
                j + $0 <= transcribed.count && generatedKeys[j..<(j + $0)].joined() == wordKeys[i]
            }) {
                ipa[i] = transcribed[j..<(j + count)].map(\.ipa).joined(separator: " ")
                i += 1
                j += count
                continue
            }
            // The model joined words: each gets a word of its IPA, if it has as many.
            if let count = (2...lookahead).first(where: {
                i + $0 <= words.count && wordKeys[i..<(i + $0)].joined() == generatedKeys[j]
            }) {
                let ipaWords = transcribed[j].ipa.split(whereSeparator: \.isWhitespace)
                if ipaWords.count == count {
                    for (offset, word) in ipaWords.enumerated() {
                        ipa[i + offset] = String(word)
                    }
                }
                i += count
                j += 1
                continue
            }
            // The model added words.
            if let next = ((j + 1)..<min(j + 1 + lookahead, transcribed.count)).first(where: { generatedKeys[$0] == wordKeys[i] }) {
                j = next
                continue
            }
            // The model left words out.
            if let next = ((i + 1)..<min(i + 1 + lookahead, words.count)).first(where: { wordKeys[$0] == generatedKeys[j] }) {
                i = next
                continue
            }
            // Another word in this one's place.
            i += 1
            j += 1
        }
        return ipa
    }

    /// What two spellings of a word are matched on: its letters and digits, without case or
    /// accents.
    private static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Normalizing

    /// `line` without emoji: a pictograph shown as one (😀, ✅, 👍🏽, 1️⃣), not a digit or a symbol
    /// such as © shown as text.
    static func withoutEmoji(_ line: String) -> String {
        var result = ""
        for character in line {
            guard let first = character.unicodeScalars.first else { continue }
            let isEmoji = first.properties.isEmojiPresentation
                || (first.properties.isEmoji && character.unicodeScalars.count > 1)
            result += isEmoji ? " " : String(character)
        }
        return result
    }

    /// Abbreviations a sentence splitter reads as sentence ends, and the model might spell out a
    /// letter at a time, written out as said. "etc." keeps its full stop where it ends a sentence:
    /// at the end of the line or before a capital. NSRegularExpression, not Swift's Regex: these
    /// need lookbehind, which Swift's doesn't support.
    private static let abbreviations: [(NSRegularExpression, String)] = [
        (pattern(#"(?<![\p{L}.])(?i:e\.g\.)(?!\p{L})"#), "for example"),
        (pattern(#"(?<![\p{L}.])(?i:i\.e\.)(?!\p{L})"#), "that is"),
        (pattern(#"(?<![\p{L}.])(?i:etc)\.(?=\s*$|\s+\p{Lu})"#), "et cetera."),
        (pattern(#"(?<![\p{L}.])(?i:etc)\.(?!\p{L})"#), "et cetera"),
        (pattern(#"(?<![\p{L}.])(?i:vs)\.?(?![\p{L}.])"#), "versus"),
    ]

    static func abbreviationsWrittenOut(_ line: String) -> String {
        abbreviations.reduce(line) { line, abbreviation in
            replacing(abbreviation.0, in: line, with: abbreviation.1)
        }
    }

    /// A hyphen or dash, slash or underscore between two letters.
    private static let joinerBetweenLetters = pattern(#"(?<=\p{L})[-‐‑–/_]+(?=\p{L})"#)

    /// Whitespace after a comma, semicolon, colon or dash: where a long sentence can be cut.
    private static let clauseBreak = pattern(#"(?<=[,;:—–])\s+"#)

    /// `pattern` compiled. The patterns are fixed literals; a typo is a programmer error the tests
    /// catch.
    private static func pattern(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    /// `text` with each match of `regex` replaced by `template`.
    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Whether `line` ends a sentence: with a full stop, question or exclamation mark, ellipsis,
    /// colon or semicolon, perhaps then closing quotes or brackets.
    private static func endsSentence(_ line: String) -> Bool {
        let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}", "»"]
        guard let last = line.last(where: { !closers.contains($0) }) else { return false }
        return ".!?…:;".contains(last)
    }

    // MARK: - Chunking

    /// `sentence` in pieces of at most `limit` characters: whole if it fits; otherwise cut after
    /// clause punctuation, then between words. A word longer than `limit` is a piece of its own.
    private static func pieces(of sentence: String, limit: Int) -> [String] {
        guard sentence.count > limit else { return [sentence] }
        var clauses: [String] = []
        var start = sentence.startIndex
        for match in clauseBreak.matches(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)) {
            guard let range = Range(match.range, in: sentence) else { continue }
            clauses.append(String(sentence[start..<range.lowerBound]))
            start = range.upperBound
        }
        clauses.append(String(sentence[start...]))
        if clauses.count > 1 {
            return packed(clauses.flatMap { pieces(of: $0, limit: limit) }, limit: limit)
        }
        let words = sentence.split(separator: " ").map(String.init)
        return packed(words, limit: limit)
    }

    /// `parts` joined with spaces into as few pieces as fit in `limit` characters, in order.
    private static func packed(_ parts: [String], limit: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        for part in parts {
            if current.isEmpty {
                current = part
            } else if current.count + 1 + part.count <= limit {
                current += " " + part
            } else {
                pieces.append(current)
                current = part
            }
        }
        if !current.isEmpty {
            pieces.append(current)
        }
        return pieces
    }

    // MARK: - Words

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
            || character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .nonspacingMark }
    }

    private static func isApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "’"
    }
}
