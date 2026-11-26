import Foundation

/// Compound words written with a capital starting each of their words, such as the class names
/// "CorpusGraph" and "MuseApplication", split into those words for every voice: "Corpus Graph",
/// "Muse Application". Said as one word, a voice guesses at it from its spelling.
///
/// A word is split where another word in it starts: at a capital after a lowercase letter
/// ("CorpusGraph"), and at a capital before a lowercase letter after a capital or a digit, so an
/// acronym stays whole ("URLSession" is "URL Session", "Base64Encoder" "Base64 Encoder"). An "s"
/// that ends the word makes the capitals before it plural, not a word of its own: "APIs" stays,
/// and "MyAPIs" is "My APIs".
///
/// Only a word that starts with a capital is split: "iPhone", "macOS" and "eBay" stay as they
/// are, as do words in capitals ("NASA") and ordinary words. So does a word that would leave a
/// letter by itself, which is more likely an abbreviation than words: "PhD", "GHz", "OAuth",
/// "LaTeX". A word with a letter or digit outside ASCII stays as it is too.
enum CompoundWords {
    /// `text` with its compound words split into their words, a space between.
    static func split(_ text: String) -> String {
        text.replacing(#/[\p{L}\p{N}]+/#) { match in
            words(in: match.output).joined(separator: " ")
        }
    }

    /// The words `word` is made of: just itself, unless it is a compound.
    private static func words(in word: Substring) -> [String] {
        let letters = Array(word)
        guard letters.first?.isUppercase == true, letters.allSatisfy(\.isASCII) else { return [String(word)] }
        var words: [String] = []
        var start = 0
        for index in letters.indices.dropFirst() where startsWord(at: index, in: letters) {
            words.append(String(letters[start..<index]))
            start = index
        }
        words.append(String(letters[start...]))
        guard !words.contains(where: { $0.count == 1 }) else { return [String(word)] }
        return words
    }

    /// Whether another word starts at `index`, after the start of `letters`.
    private static func startsWord(at index: Int, in letters: [Character]) -> Bool {
        guard letters[index].isUppercase else { return false }
        if letters[index - 1].isLowercase { return true }
        // After a capital or a digit, a capital starts a word only with a lowercase letter after
        // it, and an "s" that ends the word makes the capitals before it plural.
        let next = index + 1
        guard next < letters.endIndex, letters[next].isLowercase else { return false }
        return !(letters[next] == "s" && next == letters.endIndex - 1)
    }
}
