import Foundation

/// Numbers written out as words, for Kokoro. KokoroTTS's English phonemizer has no
/// pronunciation for digits, so "3.5", "$20" or "2026" would all come out as the same unknown
/// sound. System voices read digits themselves and get the text as it is.
///
/// Handles integers (with or without thousands separators), decimals (".5" too) and version
/// numbers, negatives, percentages, amounts in dollars, euros and pounds (with "k", "M" or "bn"
/// after them too), ordinals (1st, 22nd), times (10:30), ranges ("10-20" is "ten to twenty"),
/// and years after a word such as "in" or a month ("in 2026", "May 4, 1999"). Digits are read
/// one by one in a number with a leading zero ("0042") and in three or more numbers joined by
/// dashes (a phone number, an ISO date). Digits inside a word are spelled out too ("mp3"
/// becomes "mp three").
struct KokoroNumbers {
    private let formatter: NumberFormatter

    init() {
        formatter = NumberFormatter()
        // A fixed locale, so the words are English whatever the user's region.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .spellOut
    }

    private typealias Match = Regex<NumberPattern>.Match
    private typealias NumberPattern = (
        Substring,
        hour: Substring?, minute: Substring?,
        currency: Substring?, amount: Substring?, cents: Substring?, scale: Substring?,
        integer: Substring?, fraction: Substring?, percent: Substring?, ordinal: Substring?,
        point: Substring?, pointPercent: Substring?
    )

    /// `text` with every number in it as words.
    func spelledOut(_ text: String) -> String {
        let matches = Array(text.matches(of: pattern))
        var result = ""
        var cursor = text.startIndex
        var first = 0
        while first < matches.count {
            // The numbers joined to this one by single dashes, as in "10-20" or "555-123-4567".
            var last = first
            while last + 1 < matches.count, Self.isDash(between: matches[last], matches[last + 1], in: text) {
                last += 1
            }
            let start = matches[first].range.lowerBound
            let end = matches[last].range.upperBound
            var before = text[cursor..<start]
            var words: String
            switch last - first {
            case 0:
                words = self.words(for: matches[first], in: text)
            case 1:
                // A range: "2020–2024" is "twenty twenty to twenty twenty-four".
                words = self.words(for: matches[first], in: text) + " to " + self.words(for: matches[last], in: text)
            default:
                // Not a range: a phone number or a date, read group by group.
                words = matches[first...last].map { digitByDigit(text[$0.range]) }.joined(separator: ", ")
            }
            // A minus sign that starts a word makes the number negative.
            if let sign = before.last, sign == "-" || sign == "−" {
                let beforeSign = before.dropLast().last ?? (cursor == text.startIndex ? nil : text[text.index(before: cursor)])
                if beforeSign == nil || beforeSign?.isWhitespace == true || beforeSign == "(" || beforeSign == "[" {
                    before = before.dropLast()
                    words = "minus " + words
                }
            }
            result += before
            // Apart from letters the digits were joined to, as in "mp3" or "4K".
            if let previous = result.last, previous.isLetter, words.first?.isLetter == true {
                result += " "
            }
            result += words
            if end < text.endIndex, text[end].isLetter {
                result += " "
            }
            cursor = end
            first = last + 1
        }
        result += text[cursor...]
        return result
    }

    /// Whether `lhs` and `rhs` are joined by a hyphen or an en dash and nothing else.
    private static func isDash(between lhs: Match, _ rhs: Match, in text: String) -> Bool {
        let between = text[lhs.range.upperBound..<rhs.range.lowerBound]
        return between == "-" || between == "–"
    }

    /// One number's words.
    private func words(for match: Match, in text: String) -> String {
        if let hour = match.output.hour, let minute = match.output.minute {
            return time(hour: hour, minute: minute, following: text[match.range.upperBound...])
        }
        if let symbol = match.output.currency, let amount = match.output.amount {
            return money(symbol, amount: amount, fraction: match.output.cents, scale: match.output.scale)
        }
        if let integer = match.output.integer {
            return number(
                integer,
                fraction: match.output.fraction,
                isPercent: match.output.percent != nil,
                isOrdinal: match.output.ordinal != nil,
                preceding: text[..<match.range.lowerBound]
            )
        }
        if let point = match.output.point {
            // A decimal without its leading zero (".5"), unless the dot follows a word or a
            // number, as in "file.25".
            let digits = point.dropFirst()
            let preceding = text[..<match.range.lowerBound].last
            guard preceding?.isLetter != true, preceding?.isNumber != true else {
                return "." + cardinal(digits)
            }
            let words = "point " + digitByDigit(digits)
            return match.output.pointPercent == nil ? words : words + " percent"
        }
        return String(text[match.range])
    }

    // MARK: - Kinds of number

    /// "10:30" is "ten thirty", "9:05" "nine oh five", "10:00" "ten o'clock" (or just "ten"
    /// before AM or PM).
    private func time(hour: Substring, minute: Substring, following: Substring) -> String {
        // As a number: "09:30" is "nine thirty", not a code read digit by digit.
        guard let hours = Int(hour), let minutes = Int(minute) else { return digitByDigit(hour) }
        let hourWords = cardinal(hours)
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
    /// cents", "$2.5 million" and "$2.5M" "two point five million dollars", "$20k" "twenty
    /// thousand dollars".
    private func money(_ symbol: Substring, amount: Substring, fraction: Substring?, scale: Substring?) -> String {
        let units = Self.currencies[String(symbol)] ?? Self.dollars
        let whole = Int(amount.filter { $0 != "," })
        if let scale {
            let written = scale.trimmingCharacters(in: .whitespaces).lowercased()
            let scaleWord = Self.scaleAbbreviations[written] ?? written
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

    /// The short forms of a scale after an amount of money, lowercased: "$20k", "$2.5M", "$3bn".
    private static let scaleAbbreviations = ["k": "thousand", "m": "million", "b": "billion", "bn": "billion"]

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
                words += " point " + digitByDigit(part)
            }
        }
        return words
    }

    // MARK: - Words

    /// Digits, with or without thousands separators, as words. A leading zero means it's a code
    /// or a phone number, not an amount ("0042" is "zero zero four two"), and digits too many for
    /// a number are read one by one too.
    private func cardinal(_ digits: some StringProtocol) -> String {
        let plain = String(digits.filter { $0 != "," })
        let hasLeadingZero = plain.count > 1 && plain.first == "0" && !digits.contains(",")
        guard !hasLeadingZero, let value = Int(plain) else {
            return digitByDigit(plain)
        }
        return cardinal(value)
    }

    /// Each digit as a word, and each decimal point as "point"; anything else is left out.
    private func digitByDigit(_ text: some StringProtocol) -> String {
        text.compactMap { character -> String? in
            if character == "." { return "point" }
            guard let digit = character.wholeNumberValue, character.isASCII else { return nil }
            return cardinal(digit)
        }
        .joined(separator: " ")
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

    /// A time; or an amount of money, with any scale after it; or a number, with any decimal or
    /// version parts and a percent sign or ordinal ending; or a decimal without its leading zero.
    /// ASCII digits only. Not `Sendable`, so not shared.
    private let pattern: Regex<NumberPattern> = #/
        (?<hour>[0-9]{1,2}):(?<minute>[0-5][0-9])(?![0-9])
        |
        (?<currency>[$€£])(?<amount>[0-9]{1,3}(?:,[0-9]{3})+(?![0-9])|[0-9]+)(?<cents>\.[0-9]+)?
            (?<scale>\ +(?i:thousand|million|billion|trillion)\b|(?:[kKmMbB]|bn|BN|Bn)\b)?
        |
        (?<integer>[0-9]{1,3}(?:,[0-9]{3})+(?![0-9])|[0-9]+)(?<fraction>(?:\.[0-9]+)+)?
            (?:(?<percent>%)|(?<ordinal>(?i:st|nd|rd|th))\b)?
        |
        (?<point>\.[0-9]+)(?<pointPercent>%)?
        /#
}
