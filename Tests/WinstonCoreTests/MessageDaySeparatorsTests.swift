import Foundation
import Testing
import TelegramLink
import WinstonCore

/// The headers where a new day starts in the chat: which messages they go above, and what they say.
@Suite(.timeLimit(.minutes(1)))
struct MessageDaySeparatorsTests {
    // As in MessageTimesTests, the spelling of a date's parts comes with the OS's locale data, so
    // most of these compare with the format style meant for it.
    private static let chicago = TimeZone(identifier: "America/Chicago")!
    private static let utc = TimeZone(identifier: "UTC")!
    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private static let usEnglish = Locale(identifier: "en_US")
    private static let german = Locale(identifier: "de_DE")

    /// The date's header style, as the code builds it.
    private static func style(_ locale: Locale = usEnglish, _ timeZone: TimeZone = chicago) -> Date.FormatStyle {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        return Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone,
                                capitalizationContext: .beginningOfSentence)
    }

    /// A moment in Chicago, or in `timeZone`.
    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0,
                             in timeZone: TimeZone = chicago) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute, second: second))!
    }

    /// Sunday evening, Nov 22 2026, in Chicago.
    private static let now = date(2026, 11, 22, 20, 53)

    private static func separators(
        _ messages: [ChatMessage],
        now: Date = now,
        calendar: Calendar = Calendar(identifier: .gregorian),
        timeZone: TimeZone = chicago,
        locale: Locale = usEnglish
    ) -> [MessageID: MessageDaySeparators.Separator] {
        MessageDaySeparators.compute(messages, now: now, calendar: calendar, timeZone: timeZone, locale: locale)
    }

    /// The headers' texts by message ID, to compare whole.
    private static func texts(
        _ messages: [ChatMessage],
        now: Date = now,
        timeZone: TimeZone = chicago,
        locale: Locale = usEnglish
    ) -> [Int64: String] {
        Dictionary(uniqueKeysWithValues: separators(messages, now: now, timeZone: timeZone, locale: locale)
            .map { ($0.key.rawValue, $0.value.text) })
    }

    /// The header for the day `date` is on.
    private static func header(
        _ date: Date,
        now: Date = now,
        timeZone: TimeZone = chicago,
        locale: Locale = usEnglish
    ) -> MessageDaySeparators.Separator {
        MessageDaySeparators.separator(forDayOf: date, now: now, calendar: Calendar(identifier: .gregorian),
                                       timeZone: timeZone, locale: locale)
    }

    private static func message(_ id: Int64, at date: Date, outgoing: Bool = false,
                                sendState: SendState = .sent) -> ChatMessage {
        ChatMessage(id: MessageID(id), chatID: ChatID(1), isOutgoing: outgoing, date: date, text: "Message \(id)",
                    sendState: sendState)
    }

    private static let undated = Date(timeIntervalSince1970: 0)

    // MARK: - Which messages a header goes above

    @Test func anEmptyChatHasNoHeaders() {
        #expect(Self.separators([]).isEmpty)
    }

    @Test func onlyTheFirstMessageOfADayHasTheHeader() {
        let messages = [
            Self.message(1, at: Self.date(2026, 11, 22, 9, 0)),
            Self.message(2, at: Self.date(2026, 11, 22, 9, 1), outgoing: true),
            Self.message(3, at: Self.date(2026, 11, 22, 20, 50)),
        ]
        #expect(Self.texts(messages) == [1: "Today"])
    }

    @Test func eachNewDayStartsWithItsHeader() {
        let messages = [
            Self.message(1, at: Self.date(2026, 11, 19, 15, 42)),
            Self.message(2, at: Self.date(2026, 11, 19, 15, 43), outgoing: true),
            // A day with no messages between: Friday Nov 20 shows no header.
            Self.message(3, at: Self.date(2026, 11, 21, 8, 0)),
            Self.message(4, at: Self.date(2026, 11, 22, 7, 30), outgoing: true),
            Self.message(5, at: Self.date(2026, 11, 22, 7, 31)),
        ]
        #expect(Self.texts(messages) == [1: "Thursday", 3: "Yesterday", 4: "Today"])
    }

    @Test func midnightStartsTheNewDay() {
        let messages = [
            Self.message(1, at: Self.date(2026, 11, 21, 0, 0, 0)),
            Self.message(2, at: Self.date(2026, 11, 21, 23, 59, 59)),
            Self.message(3, at: Self.date(2026, 11, 22, 0, 0, 0)),
            Self.message(4, at: Self.date(2026, 11, 22, 0, 0, 1)),
        ]
        #expect(Self.texts(messages) == [1: "Yesterday", 3: "Today"])
    }

    @Test func aDayDaylightSavingTimeStartsOrEndsOnIsOneDay() {
        // Clocks in Chicago went from 2:00 to 3:00 on Sunday Mar 8 2026.
        let springForward = [
            Self.message(1, at: Self.date(2026, 3, 7, 23, 30)),
            Self.message(2, at: Self.date(2026, 3, 8, 1, 59)),
            Self.message(3, at: Self.date(2026, 3, 8, 3, 0)),
            Self.message(4, at: Self.date(2026, 3, 9, 0, 10)),
        ]
        #expect(Self.texts(springForward, now: Self.date(2026, 3, 9, 10, 0))
            == [1: "Saturday", 2: "Yesterday", 4: "Today"])
        // And from 2:00 back to 1:00 on Sunday Nov 1 2026, so 1:30 came twice, an hour apart.
        let firstOneThirty = Self.date(2026, 11, 1, 1, 30)
        let fallBack = [
            Self.message(1, at: Self.date(2026, 10, 31, 23, 59)),
            Self.message(2, at: firstOneThirty),
            Self.message(3, at: firstOneThirty.addingTimeInterval(3600)),
            Self.message(4, at: Self.date(2026, 11, 1, 23, 59)),
            Self.message(5, at: Self.date(2026, 11, 2, 0, 0)),
        ]
        #expect(Self.texts(fallBack, now: Self.date(2026, 11, 2, 9, 0))
            == [1: "Saturday", 2: "Yesterday", 5: "Today"])
    }

    @Test func aDayWhoseMidnightWasSkippedIsADay() {
        // In São Paulo, Nov 4 2018 began at 1:00: daylight saving time started at midnight.
        let saoPaulo = TimeZone(identifier: "America/Sao_Paulo")!
        let messages = [
            Self.message(1, at: Self.date(2018, 11, 3, 23, 30, in: saoPaulo)),
            Self.message(2, at: Self.date(2018, 11, 4, 1, 30, in: saoPaulo)),
            Self.message(3, at: Self.date(2018, 11, 5, 0, 30, in: saoPaulo)),
        ]
        #expect(Self.texts(messages, now: Self.date(2018, 11, 5, 10, 0, in: saoPaulo), timeZone: saoPaulo)
            == [1: "Saturday", 2: "Yesterday", 3: "Today"])
    }

    @Test func theDaysAreTheTimeZones() {
        // 14:00 and 16:00 UTC on Nov 22: both that day in UTC, but 23:00 on Nov 22 and 1:00 on
        // Nov 23 in Tokyo.
        let messages = [
            Self.message(1, at: Self.date(2026, 11, 22, 14, 0, in: Self.utc)),
            Self.message(2, at: Self.date(2026, 11, 22, 16, 0, in: Self.utc)),
        ]
        let now = Self.date(2026, 11, 22, 17, 0, in: Self.utc)
        #expect(Self.texts(messages, now: now, timeZone: Self.utc) == [1: "Today"])
        #expect(Self.texts(messages, now: now, timeZone: Self.tokyo) == [1: "Yesterday", 2: "Today"])
        // The calendar passed in starts in UTC: the time zone given replaces its own.
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = Self.utc
        #expect(Self.separators(messages, now: now, calendar: utcCalendar, timeZone: Self.tokyo).keys.sorted()
            == [MessageID(1), MessageID(2)])
    }

    @Test func messagesOutOfOrderEachGoUnderTheirOwnDay() {
        let messages = [
            Self.message(1, at: Self.date(2026, 11, 22, 9, 0)),
            Self.message(2, at: Self.date(2026, 11, 21, 22, 0)),
            Self.message(3, at: Self.date(2026, 11, 21, 23, 0)),
            Self.message(4, at: Self.date(2026, 11, 22, 9, 5)),
        ]
        #expect(Self.texts(messages) == [1: "Today", 2: "Yesterday", 4: "Today"])
    }

    @Test func aMessageWithoutADateGoesWithTheMessagesBeforeIt() {
        let messages = [
            // Before any message with a date: no header.
            Self.message(1, at: Self.undated),
            Self.message(2, at: Self.date(2026, 11, 21, 9, 0)),
            Self.message(3, at: Self.undated),
            Self.message(4, at: Self.date(2026, 11, 21, 9, 5)),
            Self.message(5, at: Self.undated),
            Self.message(6, at: Self.date(2026, 11, 22, 9, 0)),
        ]
        #expect(Self.texts(messages) == [2: "Yesterday", 6: "Today"])
        #expect(Self.separators([Self.message(1, at: Self.undated), Self.message(2, at: Self.undated)]).isEmpty)
    }

    @Test func aMessageSendingOrNotSentIsOnTheDayItWasTried() {
        let yesterday = Self.message(1, at: Self.date(2026, 11, 21, 22, 0))
        // The first message of today shows today's header while it is still sending.
        #expect(Self.texts([yesterday, Self.message(2, at: Self.date(2026, 11, 22, 8, 0), outgoing: true,
                                                    sendState: .pending)])
            == [1: "Yesterday", 2: "Today"])
        #expect(Self.texts([yesterday, Self.message(2, at: Self.date(2026, 11, 22, 8, 0), outgoing: true,
                                                    sendState: .failed("Network"))])
            == [1: "Yesterday", 2: "Today"])
        // One on the day before it doesn't.
        #expect(Self.texts([yesterday, Self.message(2, at: Self.date(2026, 11, 21, 23, 0), outgoing: true,
                                                    sendState: .pending)])
            == [1: "Yesterday"])
        // Nor one without a date.
        #expect(Self.separators([Self.message(1, at: Self.undated, outgoing: true, sendState: .pending)]).isEmpty)
    }

    @Test func aMessageSentAcrossMidnightMovesToTheDayItWasSent() {
        let now = Self.date(2026, 11, 23, 0, 0, 30)
        let beforeMidnight = Self.message(1, at: Self.date(2026, 11, 22, 23, 50))
        // Tried a second before midnight, so on Nov 22 while it sends.
        let sending = Self.message(2, at: Self.date(2026, 11, 22, 23, 59, 59), outgoing: true, sendState: .pending)
        #expect(Self.texts([beforeMidnight, sending], now: now) == [1: "Yesterday"])
        // Sent, with its new ID, at the server's 0:00:01 on Nov 23.
        let sent = Self.message(3, at: Self.date(2026, 11, 23, 0, 0, 1), outgoing: true)
        #expect(Self.texts([beforeMidnight, sent], now: now) == [1: "Yesterday", 3: "Today"])
    }

    // MARK: - What a header says

    @Test func todayAndYesterdayAreTheLocalesWords() {
        #expect(Self.header(Self.date(2026, 11, 22, 0, 0)).text == "Today")
        #expect(Self.header(Self.date(2026, 11, 21, 23, 59, 59)).text == "Yesterday")
        #expect(Self.header(Self.date(2026, 11, 22, 15, 42), locale: Self.german).text == "Heute")
        #expect(Self.header(Self.date(2026, 11, 21, 15, 42), locale: Self.german).text == "Gestern")
        // Relative to `now`, not the clock.
        let justAfterMidnight = Self.date(2026, 11, 22, 0, 0, 5)
        #expect(Self.header(Self.date(2026, 11, 21, 23, 59), now: justAfterMidnight).text == "Yesterday")
        #expect(Self.header(Self.date(2026, 11, 22, 0, 0), now: Self.date(2026, 11, 22, 23, 59, 59)).text == "Today")
    }

    @Test func theFiveDaysBeforeYesterdayAreWeekdays() {
        // Friday Nov 20 is two days back, Monday Nov 16 six.
        #expect(Self.header(Self.date(2026, 11, 20, 12, 0)).text == "Friday")
        #expect(Self.header(Self.date(2026, 11, 16, 0, 0)).text == "Monday")
        #expect(Self.header(Self.date(2026, 11, 20, 12, 0), locale: Self.german).text == "Freitag")
        // A week back is the same weekday as today, so it shows the date.
        let weekAgo = Self.date(2026, 11, 15, 23, 59)
        #expect(Self.header(weekAgo).text == weekAgo.formatted(Self.style().weekday(.abbreviated).month(.abbreviated).day()))
    }

    @Test func earlierThisYearIsTheDate() {
        let nov10 = Self.date(2026, 11, 10, 9, 0)
        #expect(Self.header(nov10).text == "Tue, Nov 10")
        let newYearsDay = Self.date(2026, 1, 1, 9, 0)
        #expect(Self.header(newYearsDay).text
            == newYearsDay.formatted(Self.style().weekday(.abbreviated).month(.abbreviated).day()))
        #expect(!Self.header(newYearsDay).text.contains("2026"))
        #expect(Self.header(nov10, locale: Self.german).text
            == nov10.formatted(Self.style(Self.german).weekday(.abbreviated).month(.abbreviated).day()))
    }

    @Test func anEarlierYearHasTheYear() {
        let lastYear = Self.date(2025, 11, 17, 15, 42)
        #expect(Self.header(lastYear).text == "Mon, Nov 17, 2025")
        let newYearsEve = Self.date(2025, 12, 31, 23, 59)
        #expect(Self.header(newYearsEve).text
            == newYearsEve.formatted(Self.style().weekday(.abbreviated).month(.abbreviated).day().year()))
        #expect(Self.header(lastYear, locale: Self.german).text
            == lastYear.formatted(Self.style(Self.german).weekday(.abbreviated).month(.abbreviated).day().year()))
    }

    @Test func acrossNewYearTheLastWeekIsStillWeekdays() {
        let now = Self.date(2027, 1, 2, 10, 0)
        let messages = [
            Self.message(1, at: Self.date(2026, 12, 20, 9, 0)),
            Self.message(2, at: Self.date(2026, 12, 31, 23, 0)),
            Self.message(3, at: Self.date(2027, 1, 1, 0, 30)),
            Self.message(4, at: Self.date(2027, 1, 2, 9, 0)),
        ]
        #expect(Self.texts(messages, now: now) == [1: "Sun, Dec 20, 2026", 2: "Thursday", 3: "Yesterday", 4: "Today"])
    }

    @Test func aDayAfterTodayIsItsDate() {
        // As from a clock that is ahead.
        #expect(Self.header(Self.date(2026, 11, 23, 9, 0)).text == "Mon, Nov 23")
        #expect(Self.header(Self.date(2027, 1, 3, 9, 0)).text == "Sun, Jan 3, 2027")
    }

    @Test func aHeaderStartsWithACapitalAsTheLocaleWritesIt() {
        // French writes weekdays and months in lower case, but capitalizes the first word.
        let french = Locale(identifier: "fr_FR")
        #expect(Self.header(Self.date(2026, 11, 20, 12, 0), locale: french).text == "Vendredi")
        #expect(Self.header(Self.date(2026, 11, 22, 12, 0), locale: french).text == "Aujourd’hui")
        #expect(Self.header(Self.date(2026, 11, 10, 12, 0), locale: french).text.hasPrefix("Mar"))
    }

    // MARK: - VoiceOver

    @Test func voiceOverHearsTheDayInFull() {
        #expect(Self.header(Self.date(2026, 11, 22, 9, 0)).accessibilityLabel == "Today")
        #expect(Self.header(Self.date(2026, 11, 21, 9, 0)).accessibilityLabel == "Yesterday")
        #expect(Self.header(Self.date(2026, 11, 20, 9, 0)).accessibilityLabel == "Friday")
        let nov10 = Self.date(2026, 11, 10, 9, 0)
        #expect(Self.header(nov10).accessibilityLabel == "Tuesday, November 10")
        #expect(Self.header(Self.date(2025, 11, 17, 9, 0)).accessibilityLabel == "Monday, November 17, 2025")
        #expect(Self.header(nov10, locale: Self.german).accessibilityLabel
            == nov10.formatted(Self.style(Self.german).weekday(.wide).month(.wide).day()))
    }
}
