import Foundation

/// Suggests phonemes for a word, for the Suggest button on an IPA pronunciation in settings. The
/// app has one on-device backend (`OnDevicePronunciationSuggester`); another can be added without
/// changing the settings screen.
public protocol PronunciationSuggester: Sendable {
    /// Whether it can suggest now. The on-device model, for one, isn't there on a device without
    /// Apple Intelligence, while it is turned off, or while its model downloads.
    var isAvailable: Bool { get }
    /// A sentence saying where its suggestions come from, for the suggestion list's footer, such
    /// as "Suggested by Apple Intelligence on this device."
    var attribution: String { get }
    /// A few ways to say `word`, the most likely first, with their phonemes in Kokoro's notation
    /// (see `Pronunciation.Mode.phonetic`). They may repeat each other or hold symbols Kokoro
    /// doesn't have: `PronunciationCandidate.candidates(from:symbols:)` sorts that out. Throws a
    /// `PronunciationSuggestionError`.
    func suggestions(for word: String) async throws -> [PronunciationSuggestion]
}

/// One way to say a word, as a `PronunciationSuggester` suggests it.
public struct PronunciationSuggestion: Hashable, Sendable {
    /// Kokoro phonemes, in its notation: what an IPA pronunciation's replacement holds.
    public var phonemes: String
    /// The same in plain letters, such as "WIN-stun".
    public var respelling: String
    /// What sets it apart from the others, such as "stress on the 2nd syllable". May be empty.
    public var note: String

    public init(phonemes: String, respelling: String, note: String) {
        self.phonemes = phonemes
        self.respelling = respelling
        self.note = note
    }
}

/// Why a `PronunciationSuggester` suggested nothing.
public enum PronunciationSuggestionError: String, Error, Sendable {
    /// It can't run now: see `PronunciationSuggester.isAvailable`.
    case unavailable
    /// The model's safety guardrails stopped it, or it refused.
    case declined
    /// Too many requests: it is rate limited or busy with another.
    case busy
    /// Anything else.
    case failed
}

/// A suggestion as settings lists it: with the symbols in its phonemes that Kokoro doesn't have.
/// One with any can't be used, since Kokoro would drop them.
public struct PronunciationCandidate: Hashable, Sendable, Identifiable {
    public let suggestion: PronunciationSuggestion
    /// The symbols of `suggestion.phonemes` that Kokoro doesn't have, each once, in order.
    public let unknownSymbols: [Character]

    /// Its phonemes, which no other candidate in a list has.
    public var id: String { suggestion.phonemes }

    /// Whether Kokoro has every symbol of its phonemes, so it can fill an IPA pronunciation.
    public var isUsable: Bool { unknownSymbols.isEmpty }

    /// `suggestions` as settings lists them: trimmed, without those with no phonemes or the same
    /// phonemes as one before, and with their phonemes checked against `symbols`, the ones Kokoro
    /// has (see `VoiceLoop.kokoroPhonemeSymbols()`).
    public static func candidates(from suggestions: [PronunciationSuggestion], symbols: Set<Character>) -> [PronunciationCandidate] {
        var seen: Set<String> = []
        var candidates: [PronunciationCandidate] = []
        for suggestion in suggestions {
            let phonemes = suggestion.phonemes.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phonemes.isEmpty, seen.insert(phonemes).inserted else { continue }
            let trimmed = PronunciationSuggestion(
                phonemes: phonemes,
                respelling: suggestion.respelling.trimmingCharacters(in: .whitespacesAndNewlines),
                note: suggestion.note.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            candidates.append(PronunciationCandidate(
                suggestion: trimmed,
                unknownSymbols: MisakiPhonemes.unknownSymbols(in: phonemes, symbols: symbols)
            ))
        }
        return candidates
    }
}

/// Kokoro's phoneme notation for English: misaki's, which Kokoro's dictionaries use. It is IPA,
/// with a capital letter for each of five diphthongs (A for eɪ, I for aɪ, O for oʊ, W for aʊ, Y
/// for ɔɪ), ɹ for r, ɡ (U+0261) for g, ʤ and ʧ as single symbols, ɾ for the flap in "butter", ᵊ
/// for the faint vowel before a syllabic consonant ("button", bˈʌtᵊn), and the stress marks ˈ and
/// ˌ right before the stressed vowel: hello is həlˈO.
enum MisakiPhonemes {
    /// misaki's American English symbols and stress marks: what Kokoro is known to say when its
    /// model isn't loaded to ask.
    static let usSymbols: Set<Character> = Set(consonants + vowels + "ˈˌ")

    private static let consonants = "bdfhjklmnpstvwzɡŋɹʃʒðθʤʧɾ"
    private static let vowels = "əiuɑɔɛɜɪʊʌæᵻᵊAIOWY"
    /// The vowels a stress mark goes before: all but ᵊ, which is never stressed, and the IPA
    /// vowels misaki doesn't use, which come through unconverted (Kokoro's vocabulary has some,
    /// such as y).
    private static let stressedVowels: Set<Character> = Set(vowels.filter { $0 != "ᵊ" } + "yøœɯɤɘɵɞɶ")

    /// The combining marks kept through `withoutDiacritics(_:)`: the cedilla of ç, a letter of
    /// its own in IPA, and the syllabic marks, which `symbols(in:)` reads.
    private static let keptMarks: Set<Unicode.Scalar> = ["\u{0327}", "\u{0329}", "\u{030D}"]

    /// The symbols of `phonemes` that aren't in `symbols`, each once, in order. Spaces don't count:
    /// they part the phonemes' words.
    static func unknownSymbols(in phonemes: String, symbols: Set<Character>) -> [Character] {
        var unknown: [Character] = []
        for symbol in phonemes where !symbol.isWhitespace && !symbols.contains(symbol) && !unknown.contains(symbol) {
            unknown.append(symbol)
        }
        return unknown
    }

    /// `ipa`, standard IPA for American English (such as "ˈwɪn.stən"), in misaki's notation
    /// ("wˈɪnstən"). Each word is converted on its own, and they are kept apart by one space.
    /// `asOneWord` says `ipa` is all one word, as for a word written without spaces: a space in it
    /// then only breaks syllables, as a dot does ("ˈwɪn stən" is wˈɪnstən). Symbols it doesn't
    /// convert are kept, for `unknownSymbols(in:symbols:)` to find.
    static func fromIPA(_ ipa: String, asOneWord: Bool = false) -> String {
        let words = withoutDiacritics(ipa).split(whereSeparator: \.isWhitespace).map(String.init)
        if asOneWord {
            return word(fromIPA: words.joined(separator: "."))
        }
        return words
            .map(word(fromIPA:))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// `ipa` without the diacritics misaki doesn't mark, such as the nasal tilde ([bĩn] is bin)
    /// and tie bars (t͡ʃ), whether a letter comes with its diacritic or after it. A letter of its
    /// own in IPA, such as ç, is kept, as are syllabic marks.
    private static func withoutDiacritics(_ ipa: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in ipa.decomposedStringWithCanonicalMapping.unicodeScalars
        where scalar.properties.generalCategory != .nonspacingMark || keptMarks.contains(scalar) {
            kept.append(scalar)
        }
        return String(kept).precomposedStringWithCanonicalMapping
    }

    /// One word of `fromIPA(_:asOneWord:)`.
    private static func word(fromIPA ipa: String) -> String {
        stressMoved(converted(symbols(in: ipa)))
    }

    /// `ipa`'s symbols, one string each, without what misaki doesn't mark: the slashes or brackets
    /// around a transcription, length (ː ˑ) and aspiration (ʰ); `withoutDiacritics(_:)` has taken
    /// out the diacritics. A syllabic consonant ("n̩") gets the faint vowel misaki puts before it
    /// (ᵊn), or a schwa before ɹ. Syllable breaks, a dot or a hyphen, are kept as dots, so that
    /// `converted(_:)` doesn't join the vowels on either side of one; it then drops them.
    private static func symbols(in ipa: String) -> [String] {
        var symbols: [String] = []
        for scalar in ipa.unicodeScalars {
            switch scalar {
            case "\u{0329}", "\u{030D}":
                // Syllabic, below or above.
                guard let consonant = symbols.popLast() else { continue }
                symbols += [isRhotic(consonant) ? "ə" : "ᵊ", consonant]
            case "-", "‿":
                symbols.append(".")
            case "ː", "ˑ":
                // A long e or o is the vowel of "say" or "go", even before an r: kɔˈroːro is
                // Kokoro, not "kor-or-o".
                switch symbols.last {
                case "e": symbols[symbols.count - 1] = "A"
                case "o": symbols[symbols.count - 1] = "O"
                default: continue
                }
            case "/", "[", "]", "ʰ":
                continue
            default:
                symbols.append(String(scalar))
            }
        }
        return symbols
    }

    /// Two IPA symbols that misaki writes as one.
    private static let pairs: [String: String] = [
        "eɪ": "A",
        "aɪ": "I", "ai": "I", "ɑɪ": "I", "ʌɪ": "I",
        "aʊ": "W", "au": "W", "ɑʊ": "W", "æʊ": "W",
        "ɔɪ": "Y", "oɪ": "Y", "ɔi": "Y",
        "oʊ": "O", "ou": "O", "əʊ": "O",
        "tʃ": "ʧ", "dʒ": "ʤ",
    ]

    /// IPA symbols that misaki writes otherwise, whatever comes next.
    private static let singles: [String: [String]] = [
        "r": ["ɹ"], "ɻ": ["ɹ"],
        "g": ["ɡ"],
        "ɚ": ["ə", "ɹ"], "ɝ": ["ɜ", "ɹ"],
        // On their own, in American English: the vowels of "bed" and "father", and the reduced
        // vowels. The vowel of "say" is eɪ, or eː (see `symbols(in:)`).
        "e": ["ɛ"], "a": ["ɑ"], "ɒ": ["ɑ"], "ɐ": ["ə"], "ɨ": ["ᵻ"], "ʉ": ["u"],
        "ɫ": ["l"], "ʍ": ["w"],
        ".": [],
    ]

    /// `symbols` in misaki's: diphthongs and affricates joined, and each symbol misaki writes
    /// otherwise replaced. A bare e is the vowel of "bed" (ɛ). Before an r, o is the vowel of "or"
    /// (ɔ); elsewhere, or marked long (see `symbols(in:)`), it is the diphthong of "go" (O).
    /// American English says ɜ only before an r, so one without is given it.
    private static func converted(_ symbols: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < symbols.count {
            let symbol = symbols[index]
            let next = index + 1 < symbols.count ? symbols[index + 1] : nil
            if let next, let pair = pairs[symbol + next] {
                result.append(pair)
                index += 2
                continue
            }
            let beforeR = next.map(isRhotic) ?? false
            switch symbol {
            case "o": result.append(beforeR ? "ɔ" : "O")
            case "ɜ": result += beforeR ? ["ɜ"] : ["ɜ", "ɹ"]
            default: result += singles[symbol] ?? [symbol]
            }
            index += 1
        }
        return result
    }

    /// Whether `symbol` is an r.
    private static func isRhotic(_ symbol: String) -> Bool {
        symbol == "r" || symbol == "ɹ" || symbol == "ɻ"
    }

    /// `symbols` with each stress mark moved from the start of its syllable, where IPA puts it, to
    /// right before the syllable's vowel, where misaki does. A mark with no vowel after it is
    /// dropped; of two before one vowel, primary stress wins.
    private static func stressMoved(_ symbols: [String]) -> String {
        var result = ""
        var pending: Character?
        for symbol in symbols {
            guard let character = symbol.first, symbol.count == 1 else {
                result += symbol
                continue
            }
            switch character {
            case "ˈ", "ˌ":
                pending = pending == "ˈ" ? "ˈ" : character
            case _ where stressedVowels.contains(character):
                if let mark = pending {
                    result.append(mark)
                    pending = nil
                }
                result.append(character)
            default:
                result.append(character)
            }
        }
        return result
    }
}
