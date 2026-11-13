import Foundation

/// Numbers written out as words, for Kokoro. KokoroTTS's English phonemizer has no
/// pronunciation for digits, so "3.5", "$20" or "2026" would all come out as the same unknown
/// sound, and it drops a dash with no spaces around it, gluing the words on each side together.
/// System voices read digits themselves and get the text as it is.
///
/// A number on its own is read as an integer, a decimal (".5" too) or a version, a negative, a
/// percentage, an amount of money (with "k", "M" or "bn" after it too), an ordinal, a time, a
/// decade, or a year after a word such as "in" or a month. Digits are read one by one in a
/// number with a leading zero ("0042"). Numbers next to each other follow the rules in
/// `spelledOut(_:)`. Digits inside a word are spelled out too ("mp3" becomes "mp three").
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
        decadeQuote: Substring?, decade: Substring?,
        integer: Substring?, fraction: Substring?, percent: Substring?, ordinal: Substring?, integerScale: Substring?,
        point: Substring?, pointPercent: Substring?
    )

    /// `text` with every number in it as words. Numbers next to each other are read by the first
    /// of these rules that fits:
    ///
    /// 1. A whole number, a space or a dash, and a common fraction is a mixed number: "1 1/2"
    ///    and "1-1/2" are "one and a half".
    /// 2. Numbers joined by slashes: a common fraction (denominator 2 to 10, numerator smaller)
    ///    is "three quarters"; anything else is read with a space for each slash ("24/7" is
    ///    "twenty-four seven").
    /// 3. Numbers joined by dashes (a hyphen or an en dash):
    ///    1. Glued to a word on the left, they name something: each dash is a space ("GPT-4-32k"
    ///       is "GPT four thirty-two k", "COVID-19" "COVID nineteen").
    ///    2. Three digits, a dash and four digits is a phone number, as is an area code in
    ///       parentheses before it: digit by digit, with a comma between groups.
    ///    3. Two numbers are a range: "3-2" is "three to two". A scale after the second applies
    ///       to both: "5-10k" is "five to ten thousand", "$5-10M" "five to ten million dollars".
    ///    4. Three or more are read digit by digit when every one is a plain run of digits (an
    ///       ISO date, a phone number), and otherwise each in its own words; a comma goes between.
    /// 4. Anything else is read on its own.
    func spelledOut(_ text: String) -> String {
        let matches = Array(text.matches(of: pattern))
        var result = ""
        var cursor = text.startIndex
        var index = 0
        while index < matches.count {
            let (count, read) = words(for: matches, from: index, in: text)
            let first = matches[index]
            let end = matches[index + count - 1].range.upperBound
            var before = text[cursor..<first.range.lowerBound]
            var words = read
            if Self.isGluedToWord(first, in: text) {
                // The hyphen goes; a space takes its place below.
                before = before.dropLast()
            } else if let sign = before.last, sign == "-" || sign == "−" {
                // A minus sign that starts a word makes the number negative.
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
            index += count
        }
        result += text[cursor...]
        return result
    }

    // MARK: - Numbers next to each other

    /// The words for `matches[index]` and the numbers read with it by the rules in
    /// `spelledOut(_:)`, and how many matches that took.
    private func words(for matches: [Match], from index: Int, in text: String) -> (count: Int, words: String) {
        /// The text between `matches[at]` and the match after it, if there is one.
        func link(_ at: Int) -> Substring? {
            at + 1 < matches.count ? text[matches[at].range.upperBound..<matches[at + 1].range.lowerBound] : nil
        }
        /// The last match of the run joined to `matches[at]` by `separator`s.
        func end(from at: Int, joinedBy separator: (Substring) -> Bool) -> Int {
            var end = at
            while let between = link(end), separator(between) { end += 1 }
            return end
        }
        func isPhone(_ first: Int, _ last: Int) -> Bool {
            last == first + 1 && Self.plainDigits(matches[first])?.count == 3 && Self.plainDigits(matches[last])?.count == 4
        }
        let match = matches[index]

        // 1. A mixed number.
        if let between = link(index), between == " " || Self.isDash(between), link(index + 1) == "/",
           let whole = Self.plainDigits(match),
           let fraction = fraction(matches[index + 1], matches[index + 2], afterWholeNumber: true) {
            return (3, cardinal(whole) + " and " + fraction)
        }

        // 2. Slashes.
        let slashEnd = end(from: index) { $0 == "/" }
        if slashEnd > index {
            if slashEnd == index + 1, let fraction = fraction(match, matches[slashEnd], afterWholeNumber: false) {
                return (2, fraction)
            }
            let all = matches[index...slashEnd].map { words(for: $0, in: text) }
            return (all.count, all.joined(separator: " "))
        }

        // 3. Dashes.
        let dashEnd = end(from: index, joinedBy: Self.isDash)
        let group = matches[index...dashEnd]
        if Self.isGluedToWord(match, in: text) {
            // A name's letters stay letters: "GPT-4-32k" is "thirty-two k".
            return (group.count, group.map { words(for: $0, in: text, inName: true) }.joined(separator: " "))
        }
        if isPhone(index, dashEnd) {
            return (2, group.map { digitByDigit(text[$0.range]) }.joined(separator: ", "))
        }
        // An area code: "(212)" before "555-1234".
        if dashEnd == index, Self.plainDigits(match)?.count == 3, text[..<match.range.lowerBound].last == "(",
           link(index) == ") ", isPhone(index + 1, end(from: index + 1, joinedBy: Self.isDash)) {
            return (1, digitByDigit(text[match.range]))
        }
        switch group.count {
        case 1:
            return (1, words(for: match, in: text))
        case 2:
            return (2, range(match, matches[dashEnd], in: text))
        default:
            if group.allSatisfy({ Self.plainDigits($0) != nil }) {
                return (group.count, group.map { digitByDigit(text[$0.range]) }.joined(separator: ", "))
            }
            return (group.count, group.map { words(for: $0, in: text) }.joined(separator: ", "))
        }
    }

    /// "3-2" is "three to two". A scale after the second number applies to the first too: "5-10k"
    /// is "five to ten thousand", "$5-10M" "five to ten million dollars". Without money, only a
    /// lowercase "k" is a scale, as for a number on its own.
    private func range(_ from: Match, _ to: Match, in text: String) -> String {
        if let scale = Self.scale(of: to), Self.scale(of: from) == nil,
           let low = amount(from), let high = amount(to) {
            let units = from.output.currency.map(Self.currency) ?? to.output.currency.map(Self.currency)
            if let units {
                return low + " to " + high + " " + scale + " " + units.plural
            }
            if to.output.integerScale == "k" {
                return low + " to " + high + " " + scale
            }
        }
        return words(for: from, in: text) + " to " + words(for: to, in: text)
    }

    /// "1/2" is "one half", "3/4" "three quarters", and after a whole number "1 1/2" is "one and a
    /// half". Nil unless the denominator is 2 to 10 and the numerator is smaller.
    private func fraction(_ numerator: Match, _ denominator: Match, afterWholeNumber: Bool) -> String? {
        guard let top = Self.plainDigits(numerator).flatMap({ Int($0) }),
              let bottom = Self.plainDigits(denominator).flatMap({ Int($0) }),
              let names = Self.fractionNames[bottom], (1..<bottom).contains(top) else { return nil }
        if top == 1 {
            return (afterWholeNumber ? "a " : "one ") + names.singular
        }
        return cardinal(top) + " " + names.plural
    }

    private static let fractionNames: [Int: (singular: String, plural: String)] = [
        2: ("half", "halves"), 3: ("third", "thirds"), 4: ("quarter", "quarters"), 5: ("fifth", "fifths"),
        6: ("sixth", "sixths"), 7: ("seventh", "sevenths"), 8: ("eighth", "eighths"), 9: ("ninth", "ninths"),
        10: ("tenth", "tenths"),
    ]

    /// Whether `text` is a single hyphen or en dash.
    private static func isDash(_ text: Substring) -> Bool {
        text == "-" || text == "–"
    }

    /// Whether a dash joins `match` to the word just before it, as in "COVID-19".
    private static func isGluedToWord(_ match: Match, in text: String) -> Bool {
        let start = match.range.lowerBound
        guard start > text.startIndex else { return false }
        let dash = text.index(before: start)
        guard isDash(text[dash...dash]), dash > text.startIndex else { return false }
        return text[text.index(before: dash)].isLetter
    }

    /// A match's digits if it is nothing but a run of them, as a phone number's groups are.
    private static func plainDigits(_ match: Match) -> Substring? {
        let output = match.output
        guard let integer = output.integer, output.fraction == nil, output.percent == nil,
              output.ordinal == nil, output.integerScale == nil, !integer.contains(",") else { return nil }
        return integer
    }

    // MARK: - A number on its own

    /// One number's words. `inName` keeps a letter after it a letter, as in "GPT-4-32k".
    private func words(for match: Match, in text: String, inName: Bool = false) -> String {
        let output = match.output
        if let hour = output.hour, let minute = output.minute {
            return time(hour: hour, minute: minute, following: text[match.range.upperBound...])
        }
        if let symbol = output.currency, let amount = output.amount {
            return money(symbol, amount: amount, fraction: output.cents, scale: Self.scale(of: match))
        }
        if let decade = output.decade {
            return self.decade(decade, quoted: output.decadeQuote != nil, preceding: text[..<match.range.lowerBound])
        }
        if let integer = output.integer {
            let words = number(
                integer,
                fraction: output.fraction,
                isPercent: output.percent != nil,
                isOrdinal: output.ordinal != nil,
                preceding: text[..<match.range.lowerBound]
            )
            guard let letters = output.integerScale else { return words }
            // In chat, a lowercase "k" is thousands: "10k users", "2.5k stars". Other letters,
            // even "K" ("4K screen"), stay letters without money: see `range` and `money`.
            return letters == "k" && !inName ? words + " thousand" : words + " " + letters
        }
        if let point = output.point {
            // A decimal without its leading zero (".5"), unless the dot follows a word or a
            // number, as in "file.25".
            let digits = point.dropFirst()
            let preceding = text[..<match.range.lowerBound].last
            guard preceding?.isLetter != true, preceding?.isNumber != true else {
                return "." + cardinal(digits)
            }
            let words = "point " + digitByDigit(digits)
            return output.pointPercent == nil ? words : words + " percent"
        }
        return String(text[match.range])
    }

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
    private func money(_ symbol: Substring, amount: Substring, fraction: Substring?, scale: String?) -> String {
        let units = Self.currency(symbol)
        let whole = Int(amount.filter { $0 != "," })
        if let scale {
            return decimal(amount, fraction: fraction) + " " + scale + " " + units.plural
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

    /// The number of an amount of money or of a plain number, without its unit or scale: "$5"
    /// and "5k" are both "five". Nil for anything else, such as a percentage.
    private func amount(_ match: Match) -> String? {
        let output = match.output
        if let amount = output.amount {
            return decimal(amount, fraction: output.cents)
        }
        guard let integer = output.integer, output.percent == nil, output.ordinal == nil else { return nil }
        return decimal(integer, fraction: output.fraction)
    }

    /// The scale written after a number, as a word: "million" for "$2.5M" or "$2.5 million",
    /// "thousand" for "10k".
    private static func scale(of match: Match) -> String? {
        guard let written = match.output.scale ?? match.output.integerScale else { return nil }
        let lowercased = written.trimmingCharacters(in: .whitespaces).lowercased()
        return scaleAbbreviations[lowercased] ?? lowercased
    }

    private struct Currency {
        let singular: String
        let plural: String
        let singularCent: String
        let pluralCent: String
    }

    /// The short forms of a scale, lowercased: "$20k", "$2.5M", "$3bn".
    private static let scaleAbbreviations = ["k": "thousand", "m": "million", "b": "billion", "bn": "billion"]

    private static func currency(_ symbol: Substring) -> Currency {
        switch symbol {
        case "€": Currency(singular: "euro", plural: "euros", singularCent: "cent", pluralCent: "cents")
        case "£": Currency(singular: "pound", plural: "pounds", singularCent: "penny", pluralCent: "pence")
        default: Currency(singular: "dollar", plural: "dollars", singularCent: "cent", pluralCent: "cents")
        }
    }

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
           (1000...2099).contains(year), Self.previousWord(preceding).map(Self.yearWords.contains) == true {
            return self.year(year)
        }
        let words = decimal(integer, fraction: fraction)
        return isPercent ? words + " percent" : words
    }

    /// "1990s" is "nineteen nineties" and "2000s" "two thousands". Two digits are a decade after
    /// an apostrophe or a word such as "the" or "their" ("the 90s", "'90s", "in their 20s");
    /// otherwise "30s" is more likely seconds, and stays "thirty s".
    private func decade(_ digits: Substring, quoted: Bool, preceding: Substring) -> String {
        if digits.count == 4, let year = Int(digits), (1000...2099).contains(year) {
            return Self.plural(self.year(year))
        }
        if digits.count == 2, quoted || Self.previousWord(preceding).map(Self.decadeWords.contains) == true {
            return Self.plural(cardinal(digits))
        }
        return cardinal(digits) + " s"
    }

    private static let decadeWords: Set<String> = [
        "the", "early", "mid", "late", "my", "your", "his", "her", "its", "our", "their",
    ]

    /// "ninety" becomes "nineties", "two thousand" "two thousands".
    private static func plural(_ words: String) -> String {
        words.hasSuffix("y") ? String(words.dropLast()) + "ies" : words + "s"
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

    /// The last word before a number, lowercased: "in" for "in 2026", "may" for "May 4, 2026".
    private static func previousWord(_ preceding: Substring) -> String? {
        let word = preceding.reversed().drop { !$0.isLetter }.prefix { $0.isLetter }
        return word.isEmpty ? nil : String(word.reversed()).lowercased()
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

    /// A time; an amount of money, with any scale after it; a decade ("1990s", "'90s"); a number,
    /// with any decimal or version parts and a percent sign, an ordinal ending or a scale letter;
    /// or a decimal without its leading zero. ASCII digits only. Not `Sendable`, so not shared.
    private let pattern: Regex<NumberPattern> = #/
        (?<hour>[0-9]{1,2}):(?<minute>[0-5][0-9])(?![0-9])
        |
        (?<currency>[$€£])(?<amount>[0-9]{1,3}(?:,[0-9]{3})+(?![0-9])|[0-9]+)(?<cents>\.[0-9]+)?
            (?<scale>\ +(?i:thousand|million|billion|trillion)\b|(?:[kKmMbB]|bn|BN|Bn)\b)?
        |
        (?<decadeQuote>['’])?(?<decade>[0-9]{1,3}0)['’]?s\b
        |
        (?<integer>[0-9]{1,3}(?:,[0-9]{3})+(?![0-9])|[0-9]+)(?<fraction>(?:\.[0-9]+)+)?
            (?:(?<percent>%)|(?<ordinal>(?i:st|nd|rd|th))\b|(?<integerScale>(?:[kKmMbB]|bn|BN|Bn)\b))?
        |
        (?<point>\.[0-9]+)(?<pointPercent>%)?
        /#
}
