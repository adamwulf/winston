import Foundation

/// Kokoro phonemes with every symbol Kokoro doesn't have put as the closest it does, for Speak
/// IPA, which says the model's IPA whatever it holds. `MisakiPhonemes.fromIPA(_:asOneWord:)` has
/// already turned standard IPA into misaki's notation (diphthongs, affricates, r and g, rhotic
/// vowels, length, nasal and other diacritics, tie bars, syllabic consonants); what is left that
/// Kokoro lacks is a sound English doesn't have, or a symbol for none.
///
/// A symbol Kokoro has is kept as the model wrote it, whatever it is: the loaded model's
/// vocabulary has some that misaki's US set lacks, such as ʔ and ʲ. For each symbol Kokoro lacks,
/// `table` lists what to say in its place, closest first by how it is made (the same place and
/// manner, the vowel's height, backness and rounding), the way an English speaker would say it:
/// the first whose every symbol Kokoro has is used. A symbol not in the table is put as its base
/// letter without diacritics, or in lowercase, as that letter is. Only what has no sound close to
/// it is left out: the glottal stop, tone letters, secondary articulation, length and prosodic
/// breaks, when Kokoro lacks them, and punctuation always, which Kokoro has, but which in a word
/// would be a pause.
enum ClosestPhonemes {
    /// What to say for each symbol Kokoro may not have, closest first. An empty list: nothing is
    /// close, and it is left out.
    static let table: [Character: [String]] = [
        // Vowels English doesn't have: the nearest English vowel, rounding kept where it can be.
        "y": ["u", "i"],
        "ʏ": ["ʊ", "ɪ"],
        "ø": ["ɜ", "ə"],
        "œ": ["ɜ", "ɛ"],
        "ɶ": ["æ", "ɑ"],
        "ɯ": ["u", "ʊ"],
        "ɤ": ["ʌ", "ə"],
        "ɘ": ["ə"],
        "ɵ": ["ə", "ʊ"],
        "ɞ": ["ɜ", "ʌ"],
        "ɨ": ["ᵻ", "ɪ"],
        "ʉ": ["u"],
        "ɐ": ["ə"],
        "ɒ": ["ɑ"],
        "a": ["ɑ", "æ"],
        "e": ["ɛ", "A"],
        "o": ["O", "ɔ"],
        // misaki's own vowels, should a Kokoro lack one: the next nearest.
        "ᵻ": ["ɪ", "ə"],
        "ᵊ": ["ə"],
        "ɑ": ["a", "ʌ"],
        "ɔ": ["ɑ", "O"],
        "ɛ": ["e", "æ"],
        "ɜ": ["ə", "ʌ"],
        "ɪ": ["i"],
        "ʊ": ["u"],
        "ʌ": ["ə"],
        "æ": ["ɛ", "a"],
        "ə": ["ʌ"],
        "i": ["ɪ"],
        "u": ["ʊ"],
        // misaki's diphthongs, as their two vowels, or the first.
        "A": ["eɪ", "ɛɪ", "ɛ"],
        "I": ["aɪ", "ɑɪ", "ɑ"],
        "O": ["oʊ", "ɔʊ", "ɔ"],
        "W": ["aʊ", "ɑʊ", "ɑ"],
        "Y": ["ɔɪ", "ɔ"],
        // Rhotic vowels, as a vowel and an r.
        "ɚ": ["əɹ"],
        "ɝ": ["ɜɹ", "əɹ"],
        // Fricatives English doesn't have: the stop or fricative made nearest.
        "x": ["k", "h"],
        "χ": ["k", "h"],
        "ɣ": ["ɡ"],
        "ç": ["ʃ", "h"],
        "ʝ": ["j"],
        "ɕ": ["ʃ"],
        "ʑ": ["ʒ"],
        "ʂ": ["ʃ"],
        "ʐ": ["ʒ"],
        "ɧ": ["ʃ"],
        "β": ["v", "b"],
        "ɸ": ["f"],
        "ħ": ["h"],
        "ʕ": ["h"],
        "ɦ": ["h"],
        "ʜ": ["h"],
        "ɬ": ["l"],
        "ɮ": ["l"],
        // Rhotics and laterals: English's r and l.
        "r": ["ɹ"],
        "ʁ": ["ɹ", "ɡ"],
        "ʀ": ["ɹ"],
        "ɾ": ["d", "t"],
        "ɽ": ["ɾ", "ɹ"],
        "ɻ": ["ɹ"],
        "ɺ": ["l"],
        "ʎ": ["j", "l"],
        "ʟ": ["l"],
        "ɫ": ["l"],
        "ɭ": ["l"],
        // Nasals.
        "ɲ": ["nj", "n"],
        "ɳ": ["n"],
        "ɴ": ["ŋ", "n"],
        "ɱ": ["m"],
        "ŋ": ["n"],
        // Approximants.
        "ʋ": ["v", "w"],
        "ɥ": ["w", "j"],
        "ɰ": ["w"],
        "ʍ": ["w"],
        // Stops made further forward or back, implosives and the trill: the English stop.
        "c": ["k"],
        "ɟ": ["ɡ"],
        "q": ["k"],
        "ɢ": ["ɡ"],
        "ʈ": ["t"],
        "ɖ": ["d"],
        "g": ["ɡ"],
        "ɓ": ["b"],
        "ɗ": ["d"],
        "ʄ": ["ɡ"],
        "ɠ": ["ɡ"],
        "ʛ": ["ɡ"],
        "ʙ": ["b"],
        // Affricates, as their two sounds.
        "ʤ": ["dʒ"],
        "ʧ": ["tʃ"],
        "ʦ": ["ts"],
        "ʣ": ["dz"],
        "ʨ": ["ʧ", "tʃ"],
        "ʥ": ["ʤ", "dʒ"],
        // Clicks: the English stop at the same place.
        "ǀ": ["t"],
        "ǃ": ["k"],
        "ǂ": ["t"],
        "ǁ": ["l"],
        "ʘ": ["p"],
        // The glottal stop: English mostly says nothing there.
        "ʔ": [],
        "ʡ": [],
        // Marks with no sound of their own: secondary articulation, aspiration, length, tone, and
        // prosodic breaks.
        "ʰ": [], "ʲ": [], "ʷ": [], "ˠ": [], "ˤ": [], "ⁿ": [], "ˡ": [],
        "ː": [], "ˑ": [],
        "˥": [], "˦": [], "˧": [], "˨": [], "˩": [],
        "↓": [], "↑": [], "↗": [], "↘": [], "|": [], "‖": [],
    ]

    /// A symbol put as another: `to` is empty when it was left out.
    struct Change: Hashable, Sendable {
        let from: Character
        let to: String
    }

    /// `phonemes` with each symbol not in `symbols` (the ones Kokoro has) put as the closest it
    /// has (see the type's documentation), and what changed, in order, each change once per
    /// symbol it was made for.
    static func closest(_ phonemes: String, symbols: Set<Character>) -> (phonemes: String, changes: [Change]) {
        var result = ""
        var changes: [Change] = []
        for symbol in phonemes {
            if symbols.contains(symbol), !isPunctuation(symbol) {
                result.append(symbol)
                continue
            }
            let replacement = closest(to: symbol, symbols: symbols)
            result += replacement
            changes.append(Change(from: symbol, to: replacement))
        }
        return (result, changes)
    }

    /// What to say for `symbol`, which Kokoro doesn't have, or which is punctuation: the first of
    /// its `table` entries that Kokoro has every symbol of. A symbol not in the table is put as
    /// the same letter without diacritics ("ã" as "a", and so "ɑ"), else in lowercase, as that
    /// letter is put. Else nothing.
    static func closest(to symbol: Character, symbols: Set<Character>) -> String {
        guard !isPunctuation(symbol) else { return "" }
        if let candidates = table[symbol] {
            return candidates.first { $0.allSatisfy(symbols.contains) } ?? ""
        }
        // Each step drops diacritics or case, so this ends.
        let base = String(symbol).decomposedStringWithCanonicalMapping.unicodeScalars.first.map(Character.init)
        for candidate in [base, symbol.lowercased().first] {
            guard let candidate, candidate != symbol, !isPunctuation(candidate) else { continue }
            if symbols.contains(candidate) {
                return String(candidate)
            }
            let found = closest(to: candidate, symbols: symbols)
            if !found.isEmpty {
                return found
            }
        }
        return ""
    }

    /// Whether `symbol` is punctuation or a symbol rather than a sound: Kokoro has some, but in a
    /// word's phonemes they would be a pause. The stress marks are modifier letters, not these.
    private static func isPunctuation(_ symbol: Character) -> Bool {
        symbol.isPunctuation || symbol.isSymbol || symbol.isWhitespace
    }
}
