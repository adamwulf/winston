import Foundation

/// Hyphens, en dashes and em dashes as spaces, for every voice, so it pauses a moment at each
/// one: "well-known" is said as "well known", "now—or later" as "now or later".
///
/// A hyphen or en dash next to a number stays, as it may be a minus sign, a range or a phone
/// number ("-5", "1-5", "555-1234", "-$20", "$80k–$120k", "'80s-'90s"): a system voice reads
/// those itself, and `KokoroNumbers` reads them for Kokoro. A number is a digit on either side of
/// the dash, or, after it, a sign a number starts with ("$", "€", "£", "." or a decade's
/// apostrophe) and then a digit. An em dash is never one of those, so it is always a space, as is
/// a dash with another beside it: "--" stands for an em dash, so "a while--3 hours" has no minus.
///
/// Every voice is given its text with its dashes spaced just before it says it, as with
/// `CompoundWords`, so what is shown or sent keeps them.
enum SpokenDashes {
    /// `text` with each of its hyphens and dashes a space, but for a lone hyphen or en dash next
    /// to a number.
    static func spaced(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for (index, character) in characters.enumerated() {
            if character == "—" {
                result.append(" ")
            } else if character == "-" || character == "–" {
                let isLone = !(index > 0 && isDash(characters[index - 1]))
                    && !(index + 1 < characters.count && isDash(characters[index + 1]))
                let touchesNumber = (index > 0 && isDigit(characters[index - 1]))
                    || startsNumber(at: index + 1, in: characters)
                result.append(isLone && touchesNumber ? character : " ")
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func isDash(_ character: Character) -> Bool {
        character == "-" || character == "–" || character == "—"
    }

    /// Whether a number starts at `index`: a digit, or a sign a number starts with and a digit.
    private static func startsNumber(at index: Int, in characters: [Character]) -> Bool {
        guard index < characters.count else { return false }
        if isDigit(characters[index]) { return true }
        return numberSigns.contains(characters[index])
            && index + 1 < characters.count && isDigit(characters[index + 1])
    }

    /// What a number can start with before its digits, as `KokoroNumbers` reads them: a
    /// currency, a decimal point, or the apostrophe of a decade ("'90s").
    private static let numberSigns: Set<Character> = ["$", "€", "£", ".", "'", "’"]

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }
}
