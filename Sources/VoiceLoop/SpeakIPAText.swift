import Foundation
import NaturalLanguage

/// How Speak IPA readies a message for the on-device model: as plain words (`normalized(_:)`), in
/// chunks small enough for its context window and quick enough that the first can play soon
/// (`chunks(in:)`), each cut into words and what lies between them (`segments(of:)`), so the
/// model's IPA for each word can take that word's place and the punctuation stays the message's.
public enum SpeakIPAText {
    /// The first chunk's limit, in characters: it is all the model transcribes before the first
    /// sound, about 3 s on a Mac for 13 words. A limit, not a hard bound: see `chunks(in:)`.
    public static let firstChunkLimit = 80
    /// The largest any chunk's limit grows to. A chunk can be longer: up to a quarter more when
    /// it takes the rest of the message, and a single word longer than a chunk is a chunk of its
    /// own. The model writes about 15 tokens a word (the word, its IPA, and the structure around
    /// them), so even on a 4,096-token context this leaves plenty of room.
    public static let chunkLimit = 200
    /// How much each chunk's limit grows over the one before's, up to `chunkLimit`. On a Mac the
    /// model writes about 0.24 s a word after about 0.75 s to start, and Kokoro says about 0.33 s
    /// a word, so a chunk much longer than the one before is still being written when that one
    /// has played, and leaves a silence: at 1.5 times, the silences were 0.5 to 1.5 s. It is the
    /// limit that grows, not the chunk: a chunk that ends early, at a sentence, can be followed
    /// by one up to the next limit.
    public static let chunkGrowth = 1.25

    /// `text` as words for the model to transcribe, one line per line of the message: markdown and
    /// code blocks dropped and links said as their text or "a link" (`SpokenText.speakable(_:)`),
    /// emoji left out, a few abbreviations written out, numbers as words (`KokoroNumbers`), and
    /// a hyphen, slash or underscore between letters said as a space ("well-known" is "well
    /// known"), since KokoroTTS glues the words around one together. A line that doesn't end in
    /// punctuation (a list item, a heading) ends with a full stop, so it is said as a sentence;
    /// one that ends with a comma or a dash, as hard-wrapped prose does, goes on into the next.
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
    /// order. The first has at most `firstChunkLimit` characters, so it plays soon, and each limit
    /// after it is `chunkGrowth` times the one before, up to `chunkLimit`. A chunk takes
    /// as many words as fit, then ends at the strongest break in its second half: the end of a
    /// sentence (each line is one), then a comma, semicolon, colon or dash, then any word. So a
    /// short first sentence, such as a heading, starts a chunk rather than being one, and a long
    /// one is cut where a reader would pause. A chunk takes the rest of the message, though, if
    /// that is at most a quarter over its limit, so the last chunk isn't a word or two. A word
    /// longer than a chunk is a chunk of its own. Lines stay lines in a chunk: Kokoro says each
    /// as a sentence, and a lowercase list item after a full stop doesn't run into the line before.
    public static func chunks(
        in normalized: String,
        firstChunkLimit: Int = firstChunkLimit,
        chunkLimit: Int = chunkLimit,
        chunkGrowth: Double = chunkGrowth
    ) -> [String] {
        // Each word, with punctuation, how strong a break comes after it, and whether it ends a
        // line, which stays a line break in its chunk: a lowercase list item after a full stop
        // is still a sentence of its own to the sentence splitters.
        var words: [(text: Substring, breakStrength: Int, endsLine: Bool)] = []
        for line in normalized.split(whereSeparator: \.isNewline) {
            let sentences = KokoroText.sentences(in: String(line))
            for (sentenceIndex, sentence) in sentences.enumerated() {
                let sentenceWords = sentence.split(separator: " ")
                for (index, word) in sentenceWords.enumerated() {
                    let endsSentence = index == sentenceWords.count - 1
                    let strength = if endsSentence {
                        3
                    } else if let last = word.last, ",;:—–".contains(last) {
                        2
                    } else {
                        1
                    }
                    words.append((word, strength, endsSentence && sentenceIndex == sentences.count - 1))
                }
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
            var chunk = ""
            var separator = ""
            for word in words[start..<end] {
                chunk += separator + word.text
                separator = word.endsLine ? "\n" : " "
            }
            chunks.append(chunk)
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
    /// words, and stay in step for the word after: in "Tell us how US rates changed" with "us"
    /// left out, "US" isn't taken for "us". Past that, each word is matched to the model's word in
    /// its place, only if they are the same.
    ///
    /// Each matched word's IPA, its first reading if the model wrote several
    /// (`firstReading(of:)`), without any parentheses, is converted to Kokoro's notation as one
    /// word (`MisakiPhonemes.fromIPA(_:asOneWord:)`). It is said as written instead if that is
    /// empty, if it has punctuation or a symbol not in `symbols` (the ones Kokoro has,
    /// `VoiceLoop.kokoroPhonemeSymbols`), or if the "IPA" is just the word, which the conversion
    /// would otherwise read letter by letter; for a word the model split, if any part's is empty
    /// or just that part.
    ///
    /// A full stop right after a word said with IPA that doesn't end a sentence of the chunk, as
    /// in "Mr. Smith", goes with the word: Kokoro would otherwise take it for the end of one. An
    /// ellipsis stays.
    public static func speech(of chunk: String, transcribed: [TranscribedWord], symbols: Set<Character>) -> ChunkSpeech {
        let words = words(of: chunk)
        let ipa = matchedIPA(words: words, transcribed: transcribed)
        var phonemes: [Int: String] = [:]
        var unknownSymbolWords = 0
        var emptyWords = 0
        var echoedWords = 0
        for (index, parts) in ipa {
            let cleanedParts = parts.map {
                TranscribedWord(word: $0.word, ipa: firstReading(of: $0.ipa).filter { $0 != "(" && $0 != ")" })
            }
            let converted = MisakiPhonemes.fromIPA(cleanedParts.map(\.ipa).joined(separator: " "), asOneWord: true)
            if converted.isEmpty || cleanedParts.contains(where: { MisakiPhonemes.fromIPA($0.ipa).isEmpty }) {
                emptyWords += 1
            } else if cleanedParts.contains(where: { key($0.ipa) == key($0.word) }) {
                echoedWords += 1
            } else if !MisakiPhonemes.unknownSymbols(in: converted, symbols: symbols).isEmpty
                        || converted.contains(where: { $0.isPunctuation || $0.isSymbol }) {
                // Kokoro has punctuation among its symbols, but in a word's phonemes it would be
                // a pause.
                unknownSymbolWords += 1
            } else {
                phonemes[index] = converted
            }
        }
        let sentenceEnds = Self.sentenceEnds(in: chunk)
        var parts: [IPASpeechPart] = []
        var wordIndex = 0
        // Where the segment being read starts, in UTF-16 offsets, as `sentenceEnds` are.
        var offset = 0
        for segment in segments(of: chunk) {
            switch segment {
            case .other(let original):
                var text = original
                let length = original.utf16.count
                let endsASentence = sentenceEnds.contains { $0 > offset && $0 <= offset + length }
                // A full stop then a space: not an ellipsis, nor the dot inside "README.md", nor
                // one that ends a line, which always ends a sentence.
                let isFullStop = text.first == "." && text.dropFirst().first == " "
                if case .phonemes = parts.last, isFullStop, !endsASentence {
                    // Not a sentence's end: the abbreviation's full stop goes with its word.
                    text.removeFirst()
                }
                parts.append(.text(text))
                offset += length
            case .word(let word):
                parts.append(phonemes[wordIndex].map { .phonemes(word: word, phonemes: $0) } ?? .text(word))
                wordIndex += 1
                offset += word.utf16.count
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

    /// The first reading of `ipa`, the IPA the model wrote for one word, when it wrote several:
    /// "/ˈiːðər/ /ˈaɪðər/", "ˈiːðər, ˈaɪðər" or "ˈiːðər or ˈaɪðər" are all ˈiːðər. Slashes and
    /// brackets around a transcription go, as do commas, semicolons and bars between readings.
    static func firstReading(of ipa: String) -> String {
        let first = ipa.split { "/[]|,;".contains($0) }
            .first { !$0.allSatisfy(\.isWhitespace) } ?? ""
        let words = first.split(whereSeparator: \.isWhitespace)
        let reading = words.firstIndex(of: "or").map { words[..<$0] } ?? words[...]
        return reading.joined(separator: " ")
    }

    /// Where each of `chunk`'s sentences ends, without the spaces after it, as a UTF-16 offset:
    /// the sentences `NLTokenizer` finds, as Kokoro's are found (`KokoroText.sentences(in:)`).
    private static func sentenceEnds(in chunk: String) -> Set<Int> {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = chunk
        var ends: Set<Int> = []
        tokenizer.enumerateTokens(in: chunk.startIndex..<chunk.endIndex) { range, _ in
            let end = chunk[range].lastIndex { !$0.isWhitespace }.map(chunk.index(after:)) ?? range.lowerBound
            ends.insert(end.utf16Offset(in: chunk))
            return true
        }
        return ends
    }

    /// What the model wrote for each of `words` it matches, by the word's index: its word and
    /// IPA, or for a word the model split, each part's. See `speech(of:transcribed:symbols:)`.
    private static func matchedIPA(words: [String], transcribed: [TranscribedWord]) -> [Int: [TranscribedWord]] {
        let wordKeys = words.map(key)
        let generatedKeys = transcribed.map { key($0.word) }
        var ipa: [Int: [TranscribedWord]] = [:]
        var i = 0
        var j = 0
        // How far ahead to look for the two to get back in step.
        let lookahead = 3
        // How sure it is that word `i` and the model's word `j` are the same word: 0 if they
        // differ; 2 if the words after them are the same too, so a word that only looks the same
        // isn't taken; 1 if either has no word after, with nothing to check.
        func confidence(_ i: Int, _ j: Int) -> Int {
            guard wordKeys[i] == generatedKeys[j] else { return 0 }
            guard i + 1 < words.count, j + 1 < transcribed.count else { return 1 }
            return wordKeys[i + 1] == generatedKeys[j + 1] ? 2 : 0
        }
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
                ipa[i] = [transcribed[j]]
                i += 1
                j += 1
                continue
            }
            // The model split the word.
            if let count = (2...lookahead).first(where: {
                j + $0 <= transcribed.count && generatedKeys[j..<(j + $0)].joined() == wordKeys[i]
            }) {
                ipa[i] = Array(transcribed[j..<(j + count)])
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
                        ipa[i + offset] = [TranscribedWord(word: words[i + offset], ipa: String(word))]
                    }
                }
                i += count
                j += 1
                continue
            }
            // The model added words, or left some out: whichever gets the two back in step most
            // surely, then soonest.
            var best: (confidence: Int, skipped: Int, i: Int, j: Int)?
            for k in (j + 1)..<min(j + 1 + lookahead, transcribed.count) {
                let found = (confidence(i, k), k - j, i, k)
                if found.0 > 0, best.map({ found.0 > $0.confidence || (found.0 == $0.confidence && found.1 < $0.skipped) }) ?? true {
                    best = found
                }
            }
            for m in (i + 1)..<min(i + 1 + lookahead, words.count) {
                let found = (confidence(m, j), m - i, m, j)
                if found.0 > 0, best.map({ found.0 > $0.confidence || (found.0 == $0.confidence && found.1 < $0.skipped) }) ?? true {
                    best = found
                }
            }
            if let best {
                i = best.i
                j = best.j
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
        (pattern(#"(?<![\p{L}.])(?i:etc)\.(?=["'”’»)\]]*(?:\s*$|\s+\p{Lu}))"#), "et cetera."),
        (pattern(#"(?<![\p{L}.])(?i:etc)\.(?!\p{L})"#), "et cetera"),
        // Lowercase only: "VS" is more often Visual Studio, as in "VS Code".
        (pattern(#"(?<![\p{L}.])vs\.?(?![\p{L}.])"#), "versus"),
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

    /// Whether `line` ends with punctuation, perhaps then closing quotes or brackets: a full stop,
    /// question or exclamation mark, ellipsis, colon or semicolon, which end a sentence or a
    /// clause, or a comma or a dash, after which the sentence goes on to the next line.
    private static func endsSentence(_ line: String) -> Bool {
        let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}", "»"]
        guard let last = line.last(where: { !closers.contains($0) }) else { return false }
        return ".!?…:;,-–—".contains(last)
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
