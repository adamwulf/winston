import Foundation

/// Numbers written out as words, for Kokoro. KokoroTTS's English phonemizer has no
/// pronunciation for digits, so "3.5", "$20" or "2026" would all come out as the same unknown
/// sound. System voices read digits themselves and get the text as it is.
///
/// Handles integers (with or without thousands separators), decimals and version numbers,
/// negatives, percentages, amounts in dollars, euros and pounds, ordinals (1st, 22nd), times
/// (10:30), and years after a word such as "in" or a month ("in 2026", "May 4, 1999"). Digits
/// inside a word are spelled out too ("mp3" becomes "mp three").
struct KokoroNumbers {
    private let formatter: NumberFormatter

    init() {
        formatter = NumberFormatter()
        // A fixed locale, so the words are English whatever the user's region.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .spellOut
    }

    /// `text` with every number in it as words.
    func spelledOut(_ text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        for match in text.matches(of: pattern) {
            var before = text[cursor..<match.range.lowerBound]
            var words: String
            if let hour = match.output.hour, let minute = match.output.minute {
                words = time(hour: hour, minute: minute, following: text[match.range.upperBound...])
            } else if let symbol = match.output.currency, let amount = match.output.amount {
                words = money(symbol, amount: amount, fraction: match.output.cents, scale: match.output.scale)
            } else if let integer = match.output.integer {
                words = number(
                    integer,
                    fraction: match.output.fraction,
                    isPercent: match.output.percent != nil,
                    isOrdinal: match.output.ordinal != nil,
                    preceding: text[..<match.range.lowerBound]
                )
            } else {
                continue
            }
            // A minus sign that starts a word makes the number negative; one between two
            // numbers, as in "10-20", is a dash.
            if let sign = before.last, sign == "-" || sign == "−" {
                let beforeSign = before.dropLast().last ?? (cursor == text.startIndex ? nil : text[text.index(before: cursor)])
                if beforeSign == nil || beforeSign?.isWhitespace == true || beforeSign == "(" || beforeSign == "[" {
                    before = before.dropLast()
                    words = "minus " + words
                }
            }
            result += before
            // Apart from letters the digits were joined to, as in "mp3" or "4K".
            if let last = result.last, last.isLetter {
                result += " "
            }
            result += words
            if match.range.upperBound < text.endIndex, text[match.range.upperBound].isLetter {
                result += " "
            }
            cursor = match.range.upperBound
        }
        result += text[cursor...]
        return result
    }

    // MARK: - Kinds of number

    /// "10:30" is "ten thirty", "9:05" "nine oh five", "10:00" "ten o'clock" (or just "ten"
    /// before AM or PM).
    private func time(hour: Substring, minute: Substring, following: Substring) -> String {
        let hourWords = cardinal(hour)
        guard let minutes = Int(minute) else { return hourWords }
        if minutes == 0 {
            let meridiem = following.drop { $0 == " " }.lowercased()
            let isMeridiem = ["am", "pm", "a.m", "p.m"].contains { meridiem.hasPrefix($0) }
            return isMeridiem ? hourWords : hourWords + " o'clock"
        }
        if minutes < 10 {
            return hourWords + " oh " + cardinal(minutes)
        }
        return hourWords + " " + cardinal(minutes)
    }

    /// "$20" is "twenty dollars", "$3.50" "three dollars and fifty cents", "$0.99" "ninety-nine
    /// cents", "$2.5 million" "two point five million dollars".
    private func money(_ symbol: Substring, amount: Substring, fraction: Substring?, scale: Substring?) -> String {
        let units = Self.currencies[String(symbol)] ?? Self.dollars
        let whole = Int(amount.filter { $0 != "," })
        if let scale {
            let scaleWord = scale.trimmingCharacters(in: .whitespaces).lowercased()
            return decimal(amount, fraction: fraction) + " " + scaleWord + " " + units.plural
        }
        guard let fraction, let whole else {
            return decimal(amount, fraction: nil) + " " + (whole == 1 ? units.singular : units.plural)
        }
        let digits = fraction.dropFirst()
        guard digits.count <= 2, let cents = Int(digits.count == 1 ? digits + "0" : digits) else {
            // More places than cents: read as a decimal.
            return decimal(amount, fraction: fraction) + " " + units.plural
        }
        let wholePart = cardinal(whole) + " " + (whole == 1 ? units.singular : units.plural)
        let centPart = cardinal(cents) + " " + (cents == 1 ? units.singularCent : units.pluralCent)
        if cents == 0 { return wholePart }
        if whole == 0 { return centPart }
        return wholePart + " and " + centPart
    }

    private struct Currency {
        let singular: String
        let plural: String
        let singularCent: String
        let pluralCent: String
    }

    private static let dollars = Currency(singular: "dollar", plural: "dollars", singularCent: "cent", pluralCent: "cents")

    private static let currencies: [String: Currency] = [
        "$": dollars,
        "€": Currency(singular: "euro", plural: "euros", singularCent: "cent", pluralCent: "cents"),
        "£": Currency(singular: "pound", plural: "pounds", singularCent: "penny", pluralCent: "pence"),
    ]

    /// A number on its own, or with a decimal part, a percent sign, or an ordinal ending. A
    /// four-digit whole number after a word that introduces a year is read as a year.
    private func number(
        _ integer: Substring,
        fraction: Substring?,
        isPercent: Bool,
        isOrdinal: Bool,
        preceding: Substring
    ) -> String {
        if isOrdinal, fraction == nil {
            return ordinal(cardinal(integer))
        }
        if fraction == nil, !isPercent, integer.count == 4, let year = Int(integer),
           (1000...2099).contains(year), Self.introducesYear(preceding) {
            return self.year(year)
        }
        let words = decimal(integer, fraction: fraction)
        return isPercent ? words + " percent" : words
    }

    /// "2026" is "twenty twenty-six", "1905" "nineteen oh five", "1900" "nineteen hundred", and
    /// "2000" to "2009" "two thousand", "two thousand five", and so on.
    private func year(_ year: Int) -> String {
        let century = year / 100
        let rest = year % 100
        if year % 1000 < 10 {
            return cardinal(year)
        }
        if rest == 0 {
            return cardinal(century) + " hundred"
        }
        if rest < 10 {
            return cardinal(century) + " oh " + cardinal(rest)
        }
        return cardinal(century) + " " + cardinal(rest)
    }

    /// Whether the last word before a number makes it a year: "in 2026", "since 1999", "May 4,
    /// 2026".
    private static func introducesYear(_ preceding: Substring) -> Bool {
        let word = preceding.reversed().drop { !$0.isLetter }.prefix { $0.isLetter }
        return yearWords.contains(String(word.reversed()).lowercased())
    }

    private static let yearWords: Set<String> = [
        "in", "since", "by", "from", "until", "till", "to", "before", "after", "during", "of",
        "year", "circa", "around",
        "january", "february", "march", "april", "may", "june", "july", "august", "september",
        "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    ]

    /// "3.5" is "three point five", "1.2.3" "one point two point three", "1,250" "one thousand
    /// two hundred fifty".
    private func decimal(_ integer: Substring, fraction: Substring?) -> String {
        var words = cardinal(integer)
        if let fraction {
            for part in fraction.split(separator: ".") {
                words += " point " + part.map { cardinal(String($0)) }.joined(separator: " ")
            }
        }
        return words
    }

    // MARK: - Words

    /// Digits, with or without thousands separators, as words. Digits too many for a number are
    /// read one by one.
    private func cardinal(_ digits: some StringProtocol) -> String {
        let plain = String(digits.filter { $0 != "," })
        guard let value = Int(plain) else {
            return plain.map { cardinal(String($0)) }.joined(separator: " ")
        }
        return cardinal(value)
    }

    private func cardinal(_ value: Int) -> String {
        formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// "twenty-one" becomes "twenty-first", "one hundred" "one hundredth".
    private func ordinal(_ words: String) -> String {
        let splitAt = words.lastIndex { $0 == " " || $0 == "-" }.map { words.index(after: $0) } ?? words.startIndex
        let last = String(words[splitAt...])
        let ordinal: String
        if let irregular = Self.irregularOrdinals[last] {
            ordinal = irregular
        } else if last.hasSuffix("y") {
            ordinal = String(last.dropLast()) + "ieth"
        } else {
            ordinal = last + "th"
        }
        return String(words[..<splitAt]) + ordinal
    }

    private static let irregularOrdinals = [
        "one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
        "nine": "ninth", "twelve": "twelfth",
    ]

    // MARK: - Finding numbers

    /// A time; or an amount of money; or a number, with any decimal or version parts and a
    /// percent sign or ordinal ending. ASCII digits only. Not `Sendable`, so not shared.
    private let pattern = #/
        (?<hour>[0-9]{1,2}):(?<minute>[0-5][0-9])(?![0-9])
        |
        (?<currency>[$€£])(?<amount>[0-9]{1,3}(?:,[0-9]{3})+(?![0-9])|[0-9]+)(?<cents>\.[0-9]+)?
            (?<scale>\ +(?i:thousand|million|billion|trillion)\b)?
        |
        (?<integer>[0-9]{1,3}(?:,[0-9]{3})+(?![0-9])|[0-9]+)(?<fraction>(?:\.[0-9]+)+)?
            (?:(?<percent>%)|(?<ordinal>(?i:st|nd|rd|th))\b)?
        /#
}
