import Foundation

/// Acronyms spelled out a letter at a time, for Kokoro. KokoroTTS looks every word up in
/// lowercase, and reads one its pronunciation dictionary doesn't have by guessing from the
/// spelling, so "API" comes out as "ay", "PR" as "parister" and "HTTP" as "t". System voices read
/// acronyms themselves and get the text as it is.
///
/// A run of two or more capitals is an acronym, inside a word too: "SwiftUI" is "Swift U eye",
/// "macOS" "mac O S", and "URLSession" "U R L Session", the run's last capital starting the word
/// after it. An "s" after it that ends the word makes it plural, and so does an "'s", which sounds
/// the same: "APIs" and "API's" are both "eh P eyes".
///
/// An acronym the dictionary has as a word stays as it is: "NASA", "RAM" and "SQL" are said as
/// words, and so is a word written in capitals for emphasis, such as "NOT" or "TESTED". A few the
/// dictionary has only as some other word are spelled out anyway (`alwaysSpelled`). A word with
/// any other apostrophe ("ISN'T", which KokoroTTS expands), or with a letter outside ASCII, stays
/// as it is.
struct KokoroAcronyms {
    /// The words in KokoroTTS's pronunciation dictionary, lowercased. Without them nothing is
    /// spelled out: there's no telling an acronym from a word in capitals.
    private let dictionaryWords: Set<String>

    init(dictionaryWords: Set<String>) {
        self.dictionaryWords = dictionaryWords
    }

    /// `text` with its acronyms spelled out.
    func spelledOut(_ text: String) -> String {
        guard !dictionaryWords.isEmpty else { return text }
        // Letters, with any apostrophes between them.
        return text.replacing(#/\p{L}+(?:['’]\p{L}+)*/#) { match in
            spoken(match.output)
        }
    }

    /// A word with any acronyms in it spelled out.
    private func spoken(_ word: Substring) -> String {
        guard word.allSatisfy({ $0.isASCII || Self.isApostrophe($0) }) else { return String(word) }
        guard let apostrophe = word.firstIndex(where: Self.isApostrophe) else {
            return spoken(word, possessive: nil)
        }
        // Any apostrophe but an "'s" makes a contraction ("ISN'T") or a name ("O'BRIEN").
        guard word[apostrophe...].dropFirst() == "s" else { return String(word) }
        return spoken(word[..<apostrophe], possessive: word[apostrophe...])
    }

    /// `word`, without apostrophes, with any acronyms in it spelled out. `possessive` is the
    /// "'s" after it, if any, which makes an acronym that ends the word plural.
    private func spoken(_ word: Substring, possessive: Substring?) -> String {
        // The acronyms, each with the rest of the word before it, if any.
        var parts: [String] = []
        var rest = ""
        var possessive = possessive
        var index = word.startIndex
        while index < word.endIndex {
            let runEnd = word[index...].firstIndex { !$0.isUppercase } ?? word.endIndex
            guard word.distance(from: index, to: runEnd) >= 2 else {
                rest.append(word[index])
                index = word.index(after: index)
                continue
            }
            var end = runEnd
            // What makes the acronym plural: an "s" that ends the word, or the possessive.
            var plural: Substring?
            if runEnd == word.endIndex {
                plural = possessive
            } else if word[runEnd...] == "s" {
                plural = word[runEnd...]
            } else {
                // The run's last capital starts the next word: "URLSession".
                end = word.index(before: runEnd)
            }
            if !rest.isEmpty {
                parts.append(rest)
                rest = ""
            }
            let letters = word[index..<end]
            parts.append(spelled(letters, plural: plural != nil) ?? String(letters) + (plural ?? ""))
            if plural != nil {
                possessive = nil
                index = word.endIndex
            } else {
                index = end
            }
        }
        // Unless the word ends in an acronym, a possessive stays as it is: "GitHub's".
        rest += possessive ?? ""
        if !rest.isEmpty {
            parts.append(rest)
        }
        return parts.joined(separator: " ")
    }

    /// `letters`, all capitals, spelled out, or nil to say them as the word the dictionary has.
    /// `plural` adds an "s" to the last letter's name.
    private func spelled(_ letters: Substring, plural: Bool) -> String? {
        if letters.count >= 2, !Self.alwaysSpelled.contains(String(letters)), isKnown(letters.lowercased()) {
            return nil
        }
        var names = letters.map { Self.letterNames[$0] ?? String($0) }
        if plural, let last = letters.last {
            names[names.count - 1] = Self.pluralLetterNames[last] ?? String(last) + "s"
        }
        return names.joined(separator: " ")
    }

    /// Whether KokoroTTS reads `word` (lowercase) from its dictionary: it is there, or it is a
    /// word there with an "s", "ed" or "ing" ending, which KokoroTTS takes off to look it up.
    private func isKnown(_ word: String) -> Bool {
        if dictionaryWords.contains(word) { return true }
        return Self.stems(of: word).contains { dictionaryWords.contains($0) }
    }

    /// The words `word` could be with an ending taken off, as KokoroTTS's phonemizer tries them.
    private static func stems(of word: String) -> [String] {
        var stems: [String] = []
        if word.hasSuffix("s"), word.count > 2 {
            if word.hasSuffix("ies") { stems.append(String(word.dropLast(3)) + "y") }
            if word.hasSuffix("es"), word.count > 3 { stems.append(String(word.dropLast(2))) }
            stems.append(String(word.dropLast()))
        }
        if word.hasSuffix("ed"), word.count > 3 {
            if word.hasSuffix("ied") { stems.append(String(word.dropLast(3)) + "y") }
            stems += withoutDoubledLetter(String(word.dropLast(2)))
        }
        if word.hasSuffix("ing"), word.count > 4 {
            let stem = String(word.dropLast(3))
            stems += withoutDoubledLetter(stem) + [stem + "e"]
        }
        return stems
    }

    /// `stem`, and before it `stem` without its last letter if that letter is doubled ("stopp").
    private static func withoutDoubledLetter(_ stem: String) -> [String] {
        guard let last = stem.last, stem.dropLast().last == last else { return [stem] }
        return [String(stem.dropLast()), stem]
    }

    private static func isApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "’"
    }

    /// Acronyms the dictionary has only as some other word, which is rarely what they mean in
    /// capitals: "AM" in "10 AM" is not "am", "ID" is not "id".
    private static let alwaysSpelled: Set<String> = ["AM", "EST", "ETA", "ID", "LED", "OS"]

    /// How a letter is written for KokoroTTS to say its name, where the letter itself won't do:
    /// "A" reads as the article "a" before a noun, and "I" as the unstressed pronoun. Every other
    /// letter is in the dictionary as its name.
    private static let letterNames: [Character: String] = ["A": "eh", "I": "eye"]

    /// A letter's name with an "s", as in "APIs", written as words in the dictionary or as words
    /// KokoroTTS finds there once the "s" is off. "Rs" is neither, but KokoroTTS's guess at it
    /// comes out right.
    private static let pluralLetterNames: [Character: String] = [
        "A": "ehs", "B": "bees", "C": "sees", "D": "dees", "E": "ease", "F": "effs", "G": "gees",
        "H": "aitches", "I": "eyes", "J": "jays", "K": "kays", "L": "ells", "M": "ems", "N": "ens",
        "O": "ohs", "P": "pees", "Q": "cues", "R": "Rs", "S": "esses", "T": "tees", "U": "ewes",
        "V": "vees", "W": "double ewes", "X": "exes", "Y": "wise", "Z": "zees",
    ]
}
