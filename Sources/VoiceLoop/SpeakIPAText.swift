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
    /// one that ends with a comma or a dash, as hard-wrapped prose does, keeps it, and
    /// `chunks(in:)` joins it to the next line.
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
    /// A line ending with a comma or a dash, as hard-wrapped prose does, is joined to the next
    /// with a space instead.
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
            // A line ending with a comma or dash goes on into the next, on the same line.
            let continues = lastBeforeClosers(line).map { ",-–—".contains($0) } ?? false
            let sentences = KokoroText.sentences(in: String(line))
            for (sentenceIndex, sentence) in sentences.enumerated() {
                let sentenceWords = sentence.split(separator: " ")
                for (index, word) in sentenceWords.enumerated() {
                    let endsSentence = index == sentenceWords.count - 1
                    let endsLine = endsSentence && sentenceIndex == sentences.count - 1
                    let strength = if endsSentence && !(endsLine && continues) {
                        3
                    } else if let last = lastBeforeClosers(word), ",;:—–-".contains(last) {
                        2
                    } else {
                        1
                    }
                    words.append((word, strength, endsLine && !continues))
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
    /// with what had to change, for the note under the bubble and the logs.
    public struct ChunkSpeech: Equatable, Sendable {
        /// A symbol of a word's IPA that Kokoro doesn't have, put as the closest it has (`to`), or
        /// left out (`to` empty).
        public struct Change: Hashable, Sendable {
            public let word: String
            public let from: Character
            public let to: String
        }

        /// The chunk's parts, in order: each word the model wrote IPA for as its phonemes, and
        /// everything else (punctuation, spaces, words with no IPA to say) as written.
        public let parts: [IPASpeechPart]
        /// The chunk's words.
        public let words: Int
        /// The entries the model wrote.
        public let generated: Int
        /// Words said from the model's IPA, some perhaps with a symbol changed (`changes`).
        public let wordsWithIPA: Int
        /// Each symbol changed in a word said from the model's IPA, in order.
        public let changes: [Change]
        /// Words the model wrote no IPA for (it left them out, or wrote another word in their
        /// place): said as Kokoro reads them.
        public let wordsWithoutIPA: [String]
        /// Words whose IPA held no sound Kokoro could say once converted (empty, or only symbols
        /// left out): said as Kokoro reads them.
        public let wordsWithNothingToSay: [String]
    }

    /// `chunk` with the model's IPA in place of its words. Each of the model's words is matched to
    /// the chunk's in order, whatever their case, accents or apostrophes; a word the model split
    /// in two or three ("itsy bitsy" for "itsybitsy") gets their IPA as one word, and words it
    /// joined into one get its IPA's words, if it has as many; otherwise ("well-known" as
    /// ˌwɛlˈnoʊn for "well known") they are said together from its IPA, as one word, if only
    /// spaces lie between them. A word the model added is skipped,
    /// and one it left out has no IPA, as long as the two get back in step within three
    /// words, preferring a match the word after bears out: in "Tell us how US rates changed" with
    /// "us" left out, "US" isn't taken for "us". Past that, each word is matched to the model's
    /// word in its place, only if they are the same.
    ///
    /// Each matched word's IPA, its first reading if the model wrote several
    /// (`firstReading(of:)`), without any parentheses, is converted to Kokoro's notation as one
    /// word (`MisakiPhonemes.fromIPA(_:asOneWord:)`), and each symbol not in `symbols` (the ones
    /// Kokoro has, `VoiceLoop.kokoroPhonemeSymbols`) is put as the closest one Kokoro has, or left
    /// out if none is close (`ClosestPhonemes`). The word is said from that, whatever the model
    /// wrote; only a word the model wrote no IPA for, or whose IPA holds no sound once converted,
    /// is said as Kokoro reads it. Each is recorded.
    ///
    /// A full stop right after a word said with IPA that doesn't end a sentence of the chunk, as
    /// in "Mr. Smith", goes with the word: Kokoro would otherwise take it for the end of one. An
    /// ellipsis stays.
    public static func speech(of chunk: String, transcribed: [TranscribedWord], symbols: Set<Character>) -> ChunkSpeech {
        let segments = segments(of: chunk)
        let words = words(of: chunk)
        var (ipa, spans) = matchedIPA(words: words, transcribed: transcribed)
        // What comes after each word, by its index.
        var after: [Int: String] = [:]
        var wordCount = 0
        for segment in segments {
            switch segment {
            case .word: wordCount += 1
            case .other(let text) where wordCount > 0: after[wordCount - 1] = text
            case .other: break
            }
        }
        // Words said together are only ever words with spaces between: punctuation between, which
        // could end a sentence, would go. Otherwise the model wrote no IPA for them.
        for (start, count) in spans where !(start..<(start + count - 1)).allSatisfy({ after[$0]?.allSatisfy(\.isWhitespace) ?? false }) {
            ipa[start] = nil
            spans[start] = nil
        }
        /// The words said from the entry at `index`: one, or all those it is for together.
        func wordsOf(_ index: Int) -> ArraySlice<String> {
            words[index..<(index + (spans[index] ?? 1))]
        }
        var phonemes: [Int: String] = [:]
        var changes: [ChunkSpeech.Change] = []
        var wordsWithNothingToSay: [String] = []
        for (index, parts) in ipa.sorted(by: { $0.key < $1.key }) {
            let word = wordsOf(index).joined(separator: " ")
            let ipaText = parts
                .map { firstReading(of: $0.ipa).filter { $0 != "(" && $0 != ")" } }
                .joined(separator: " ")
            let converted = MisakiPhonemes.fromIPA(ipaText, asOneWord: true)
            let closest = ClosestPhonemes.closest(converted, symbols: symbols)
            changes += closest.changes.map { ChunkSpeech.Change(word: word, from: $0.from, to: $0.to) }
            // A sound, not only stress marks.
            if closest.phonemes.contains(where: { $0 != "ˈ" && $0 != "ˌ" }) {
                phonemes[index] = closest.phonemes
            } else {
                wordsWithNothingToSay += wordsOf(index)
            }
        }
        let covered = Set(spans.flatMap { ($0.key + 1)..<($0.key + $0.value) })
        let sentenceEnds = Self.sentenceEnds(in: chunk)
        var parts: [IPASpeechPart] = []
        var wordIndex = 0
        // Where the segment being read starts, in UTF-16 offsets, as `sentenceEnds` are.
        var offset = 0
        // Words said together, being gathered: the last one's index, their text so far, and their
        // phonemes.
        var together: (last: Int, text: String, phonemes: String)?
        for segment in segments {
            switch segment {
            case .other(let original) where together != nil:
                together?.text += original
                offset += original.utf16.count
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
                if var gathering = together {
                    gathering.text += word
                    if wordIndex == gathering.last {
                        parts.append(.phonemes(word: gathering.text, phonemes: gathering.phonemes))
                        together = nil
                    } else {
                        together = gathering
                    }
                } else if let count = spans[wordIndex], let wordPhonemes = phonemes[wordIndex] {
                    together = (wordIndex + count - 1, word, wordPhonemes)
                } else {
                    parts.append(phonemes[wordIndex].map { .phonemes(word: word, phonemes: $0) } ?? .text(word))
                }
                wordIndex += 1
                offset += word.utf16.count
            }
        }
        return ChunkSpeech(
            parts: parts,
            words: words.count,
            generated: transcribed.count,
            wordsWithIPA: phonemes.keys.reduce(0) { $0 + (spans[$1] ?? 1) },
            changes: changes,
            wordsWithoutIPA: words.indices.filter { ipa[$0] == nil && !covered.contains($0) }.map { words[$0] },
            wordsWithNothingToSay: wordsWithNothingToSay
        )
    }

    /// The first reading of `ipa`, the IPA the model wrote for one word, when it wrote several:
    /// "/ˈiːðər/ /ˈaɪðər/", "ˈiːðər, ˈaɪðər" or "ˈiːðər or ˈaɪðər" are all ˈiːðər. Slashes and
    /// brackets around a transcription go. A comma, semicolon, bar or "or" counts only between two
    /// readings: one after the only reading stays, inside its slashes or not ("həˈloʊ," or
    /// "/həˈloʊ/,"), as do quotes around it, for `ClosestPhonemes` to leave out, and record.
    static func firstReading(of ipa: String) -> String {
        let pieces = ipa.split { "/[]".contains($0) }
        let readings = pieces.filter(isReading)
        // Of one reading, or none, the punctuation around it ("“/həˈloʊ/”") stays, to be recorded.
        let reading = readings.count <= 1 ? Substring(pieces.joined()) : readings[0]
        return firstListed(reading).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The IPA the model wrote for words it joined into one entry, a word of it for each: its
    /// first listed reading (`firstListed(_:)`, so "ˈdeɪtəbeɪs, ˈdætəbeɪs" is one), parted at
    /// spaces, slashes and brackets ("/rid/ /ðɪs/" is rid and ðɪs). Punctuation stays with the
    /// word of IPA beside it, to be recorded.
    static func joinedReadingWords(of ipa: String) -> [String] {
        var words: [String] = []
        for piece in firstListed(Substring(ipa)).split(whereSeparator: { $0.isWhitespace || "/[]".contains($0) }) {
            if let last = words.last, !isReading(piece) || !isReading(Substring(last)) {
                words[words.count - 1] += piece
            } else {
                words.append(String(piece))
            }
        }
        return words
    }

    /// The first of the readings `ipa` lists, parted by a comma, semicolon, bar or "or" with a
    /// reading on both sides; all of it if it lists one, so "həˈloʊ," keeps its comma.
    private static func firstListed(_ ipa: Substring) -> Substring {
        let listed = ipa.split { ",;|".contains($0) }.filter(isReading)
        let reading = listed.count > 1 ? listed[0] : ipa
        let words = reading.split(whereSeparator: \.isWhitespace)
        if let or = words.firstIndex(of: "or"), words[..<or].contains(where: isReading),
           words[(or + 1)...].contains(where: isReading) {
            return Substring(words[..<or].joined(separator: " "))
        }
        return reading
    }

    /// Whether `piece` holds a reading: a letter, as every IPA symbol for a sound is, not only
    /// punctuation, bars or spaces.
    private static func isReading(_ piece: Substring) -> Bool {
        piece.contains(where: \.isLetter)
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
    /// IPA, or for a word the model split, each part's. `spans` has, by its first word's index,
    /// how many words one entry is for together: words the model joined, with IPA that can't be
    /// told apart word by word. See `speech(of:transcribed:symbols:)`.
    private static func matchedIPA(
        words: [String],
        transcribed: [TranscribedWord]
    ) -> (ipa: [Int: [TranscribedWord]], spans: [Int: Int]) {
        let wordKeys = words.map(key)
        let generatedKeys = transcribed.map { key($0.word) }
        var ipa: [Int: [TranscribedWord]] = [:]
        var spans: [Int: Int] = [:]
        var i = 0
        var j = 0
        // How far ahead to look for the two to get back in step.
        let lookahead = 3
        // How sure it is that word `i` and the model's word `j` are the same word: 0 if they
        // differ; 3 if the words after them are the same too, so a word that only looks the same
        // isn't taken while one borne out is near; 2 if either has no word after, with nothing
        // to check; 1 if the words after differ, as when the model left out another word.
        func confidence(_ i: Int, _ j: Int) -> Int {
            guard wordKeys[i] == generatedKeys[j] else { return 0 }
            guard i + 1 < words.count, j + 1 < transcribed.count else { return 2 }
            return wordKeys[i + 1] == generatedKeys[j + 1] ? 3 : 1
        }
        // How many words from `i` the model's word `j` is, joined: two or more whose letters
        // make its letters.
        func joinedCount(_ i: Int, _ j: Int) -> Int? {
            let target = generatedKeys[j]
            var joined = wordKeys[i]
            var count = 1
            while i + count < words.count, joined.count < target.count, target.hasPrefix(joined) {
                joined += wordKeys[i + count]
                count += 1
            }
            return count > 1 && joined == target ? count : nil
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
            // The model joined words, as many as it takes ("state-of-the-art" for "state of the
            // art"): each gets a word of its IPA, if it has as many; otherwise all of its first
            // reading is for the words together (`joinedReadingWords(of:)`).
            if let count = joinedCount(i, j) {
                let ipaWords = joinedReadingWords(of: transcribed[j].ipa)
                if ipaWords.count == count {
                    for (offset, word) in ipaWords.enumerated() {
                        ipa[i + offset] = [TranscribedWord(word: words[i + offset], ipa: word)]
                    }
                } else {
                    ipa[i] = [TranscribedWord(word: transcribed[j].word, ipa: ipaWords.joined(separator: " "))]
                    spans[i] = count
                }
                i += count
                j += 1
                continue
            }
            // The model added words, left some out, or wrote another word in this one's place:
            // whichever gets the two back in step most surely, then soonest. Another word in its
            // place is weighed first, so it wins a tie: "A step at a time" for "One step at a
            // time" goes on from "step", not from the later "a".
            var best: (confidence: Int, skipped: Int, i: Int, j: Int)?
            if i + 1 < words.count, j + 1 < transcribed.count, confidence(i + 1, j + 1) > 0 {
                best = (confidence(i + 1, j + 1), 1, i + 1, j + 1)
            }
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
        return (ipa, spans)
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
        (pattern(#"(?<![\p{L}.])(?i:etc)\.(?=["'”’»)\]]*(?:\s*$|\s+["'“‘«(\[]*\p{Lu}))"#), "et cetera."),
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
        guard let last = lastBeforeClosers(line[...]) else { return false }
        return ".!?…:;,-–—".contains(last)
    }

    /// The last character of `text` before any closing quotes or brackets: the comma of
    /// "“Wait,”".
    private static func lastBeforeClosers(_ text: Substring) -> Character? {
        let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}", "»"]
        return text.last { !closers.contains($0) }
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
