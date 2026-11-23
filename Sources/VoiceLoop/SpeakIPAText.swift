import Foundation

/// How Speak IPA readies a message for the on-device model: as plain words (`normalized(_:)`), in
/// chunks small enough for its context window and quick enough that the first can play soon
/// (`chunks(in:)`), each cut into words and what lies between them (`segments(of:)`), so the
/// model's IPA for each word can take that word's place and the punctuation stays the message's.
public enum SpeakIPAText {
    /// The most characters the first chunk has: it is all the model transcribes before the first
    /// sound, about 3 s on a Mac for 13 words.
    public static let firstChunkLimit = 80
    /// The most characters any chunk has. The model writes about 15 tokens a word (the word, its
    /// IPA, and the structure around them), so even on a 4,096-token context this leaves plenty
    /// of room.
    public static let chunkLimit = 200
    /// How much longer each chunk may be than the one before, up to `chunkLimit`. On a Mac the
    /// model writes about 0.24 s a word after about 0.75 s to start, and Kokoro says about 0.33 s
    /// a word, so a chunk much longer than the one before is still being written when that one
    /// has played, and leaves a silence: at 1.5 times, the silences were 0.5 to 1.5 s.
    public static let chunkGrowth = 1.25

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
    /// order. The first has at most `firstChunkLimit` characters, so it plays soon, and each after
    /// it at most `chunkGrowth` times as many as the one before, up to `chunkLimit`. A chunk takes
    /// as many words as fit, then ends at the strongest break in its second half: the end of a
    /// sentence (each line is one), then a comma, semicolon, colon or dash, then any word. So a
    /// short first sentence, such as a heading, starts a chunk rather than being one, and a long
    /// one is cut where a reader would pause. A chunk takes the rest of the message, though, if
    /// that is at most a quarter over its limit, so the last chunk isn't a word or two. A word
    /// longer than a chunk is a chunk of its own.
    public static func chunks(
        in normalized: String,
        firstChunkLimit: Int = firstChunkLimit,
        chunkLimit: Int = chunkLimit,
        chunkGrowth: Double = chunkGrowth
    ) -> [String] {
        // Each word, with punctuation, and how strong a break comes after it.
        var words: [(text: Substring, breakStrength: Int)] = []
        for sentence in KokoroText.sentences(in: normalized) {
            let sentenceWords = sentence.split(separator: " ")
            for (index, word) in sentenceWords.enumerated() {
                let strength = if index == sentenceWords.count - 1 {
                    3
                } else if let last = word.last, ",;:—–".contains(last) {
                    2
                } else {
                    1
                }
                words.append((word, strength))
            }
        }
        var chunks: [String] = []
        var start = 0
        while start < words.count {
            let grown = Double(firstChunkLimit) * pow(chunkGrowth, Double(chunks.count))
            let limit = grown < Double(chunkLimit) ? Int(grown) : chunkLimit
            // Where each break would end the chunk, and how long it would be: at least one word.
            var breaks: [(end: Int, length: Int)] = [(start + 1, words[start].text.count)]
            while let last = breaks.last, last.end < words.count, last.length + 1 + words[last.end].text.count <= limit {
                breaks.append((last.end + 1, last.length + 1 + words[last.end].text.count))
            }
            var end = breaks[breaks.count - 1].end
            let rest = words[start...].reduce(-1) { $0 + 1 + $1.text.count }
            if end < words.count, rest * 4 <= limit * 5 {
                // The rest of the message is within a quarter more: one chunk, rather than a last
                // chunk of a word or two.
                end = words.count
            } else if end < words.count {
                // The words run on: the strongest break in the second half, the latest of those.
                var strongest = 0
                for candidate in breaks where candidate.length * 2 >= limit {
                    let strength = words[candidate.end - 1].breakStrength
                    if strength >= strongest {
                        strongest = strength
                        end = candidate.end
                    }
                }
            }
            chunks.append(words[start..<end].map(\.text).joined(separator: " "))
            start = end
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

    // MARK: - Words

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
            || character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .nonspacingMark }
    }

    private static func isApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "’"
    }
}
