import Foundation
import Testing
import TelegramLink
import WinstonCore

/// The times for the chat's bubbles: how they read, and which bubbles show one.
@Suite(.timeLimit(.minutes(1)))
struct MessageTimesTests {
    // The spaces, punctuation and joining words ("at") between a time's parts come with the OS's
    // locale data, which can change, so these check which parts a time shows, comparing with the
    // format style meant for it where a part's spelling isn't plain.
    private static let chicago = TimeZone(identifier: "America/Chicago")!
    private static let usEnglish = Locale(identifier: "en_US")
    private static let british = Locale(identifier: "en_GB")
    private static let german = Locale(identifier: "de_DE")

    private static func style(_ locale: Locale = usEnglish, _ timeZone: TimeZone = chicago) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: Calendar(identifier: .gregorian), timeZone: timeZone)
    }

    /// A moment in Chicago.
    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0,
                             in timeZone: TimeZone = chicago) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute, second: second))!
    }

    /// Sunday evening, Nov 22 2026, in Chicago.
    private static let now = date(2026, 11, 22, 20, 53)

    private static func times(now: Date = now, timeZone: TimeZone = chicago, locale: Locale = usEnglish) -> MessageTimes {
        MessageTimes(now: now, calendar: Calendar(identifier: .gregorian), timeZone: timeZone, locale: locale)
    }

    private static func message(_ id: Int64, outgoing: Bool, at date: Date, sendState: SendState = .sent) -> ChatMessage {
        ChatMessage(id: MessageID(id), chatID: ChatID(1), isOutgoing: outgoing, date: date, text: "Message \(id)",
                    sendState: sendState)
    }

    // MARK: - Text

    @Test func todayShowsTheTimeOnlyInTheLocalesHourCycle() {
        let afternoon = Self.date(2026, 11, 22, 15, 42)
        let text = Self.times().text(for: afternoon)
        #expect(text == afternoon.formatted(Self.style().hour().minute()))
        #expect(text.hasPrefix("3:42") && text.hasSuffix("PM"))
        #expect(Self.times(locale: Self.british).text(for: afternoon) == "15:42")
        // The 24-hour setting, as it reaches Locale.current.
        #expect(Self.times(locale: Locale(identifier: "en_US@hours=h23")).text(for: afternoon) == "15:42")
        let justAfterMidnight = Self.times().text(for: Self.date(2026, 11, 22, 0, 5))
        #expect(justAfterMidnight.hasPrefix("12:05") && justAfterMidnight.hasSuffix("AM"))
    }

    @Test func yesterdayShowsTheWordAndTheTime() throws {
        // DateFormatter names the day against the clock, so these are relative to the real today.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.chicago
        let now = Date.now
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: now))
        let afternoon = try #require(calendar.date(bySettingHour: 15, minute: 42, second: 0, of: yesterday))
        let text = Self.times(now: now).text(for: afternoon)
        #expect(text.hasPrefix("Yesterday") && text.contains("3:42") && text.hasSuffix("PM"))
        let british = Self.times(now: now, locale: Self.british).text(for: afternoon)
        #expect(british.hasPrefix("Yesterday") && british.hasSuffix("15:42"))
        let german = Self.times(now: now, locale: Self.german).text(for: afternoon)
        #expect(german.hasPrefix("Gestern") && german.hasSuffix("15:42"))
    }

    @Test func earlierThisYearShowsTheDayAndTime() {
        let nov19 = Self.date(2026, 11, 19, 15, 42)
        let text = Self.times().text(for: nov19)
        #expect(text == nov19.formatted(Self.style().month(.abbreviated).day().hour().minute()))
        #expect(!text.contains("2026"))
        let newYearsDay = Self.date(2026, 1, 1, 9, 5)
        #expect(Self.times().text(for: newYearsDay)
            == newYearsDay.formatted(Self.style().month(.abbreviated).day().hour().minute()))
        #expect(Self.times(locale: Self.german).text(for: nov19)
            == nov19.formatted(Self.style(Self.german).month(.abbreviated).day().hour().minute()))
    }

    @Test func anEarlierYearShowsTheYearToo() {
        let lastYear = Self.date(2025, 11, 19, 15, 42)
        let text = Self.times().text(for: lastYear)
        #expect(text == lastYear.formatted(Self.style().year().month(.abbreviated).day().hour().minute()))
        #expect(text.contains("2025"))
        let newYearsEve = Self.date(2025, 12, 31, 23, 59)
        #expect(Self.times().text(for: newYearsEve)
            == newYearsEve.formatted(Self.style().year().month(.abbreviated).day().hour().minute()))
    }

    @Test func theTimeAndTheDayAreTheTimeZones() {
        let utc = TimeZone(identifier: "UTC")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        // 11:53 UTC: 20:53 in Tokyo, both on Nov 22.
        let now = Self.date(2026, 11, 22, 11, 53, in: utc)
        let sent = Self.date(2026, 11, 22, 5, 30, in: utc)
        #expect(Self.times(now: now, timeZone: utc, locale: Self.british).text(for: sent) == "05:30")
        #expect(Self.times(now: now, timeZone: tokyo, locale: Self.british).text(for: sent) == "14:30")
        // 8 AM on Nov 21 in Chicago is 11 PM in Tokyo, two days before Tokyo's Nov 23 (but yesterday
        // in UTC). The calendar passed in starts in UTC: the time zone given replaces its own.
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = utc
        let tokyoTomorrow = Self.date(2026, 11, 23, 0, 30, in: tokyo)
        let sentEarlier = Self.date(2026, 11, 21, 8, 0)
        let times = MessageTimes(now: tokyoTomorrow, calendar: utcCalendar, timeZone: tokyo, locale: Self.usEnglish)
        #expect(times.text(for: sentEarlier)
            == sentEarlier.formatted(Self.style(Self.usEnglish, tokyo).month(.abbreviated).day().hour().minute()))
    }

    // MARK: - Which bubbles show a time

    @Test func onlyTheLastOfARunFromOneSideInOneMinuteShowsTheTime() {
        let messages = [
            Self.message(1, outgoing: true, at: Self.date(2026, 11, 22, 15, 42, 5)),
            Self.message(2, outgoing: true, at: Self.date(2026, 11, 22, 15, 42, 20)),
            Self.message(3, outgoing: true, at: Self.date(2026, 11, 22, 15, 42, 59)),
            Self.message(4, outgoing: false, at: Self.date(2026, 11, 22, 15, 42, 59)),
            Self.message(5, outgoing: false, at: Self.date(2026, 11, 22, 15, 42, 59)),
        ]
        #expect(Self.times().messagesShowingTime(in: messages) == [MessageID(3), MessageID(5)])
    }

    @Test func eachMinuteAndEachSideShowsItsOwnTime() {
        let messages = [
            // A second apart, but in different minutes.
            Self.message(1, outgoing: false, at: Self.date(2026, 11, 22, 15, 42, 59)),
            Self.message(2, outgoing: false, at: Self.date(2026, 11, 22, 15, 43, 0)),
            // The same minute, but the other side.
            Self.message(3, outgoing: true, at: Self.date(2026, 11, 22, 15, 43, 10)),
            Self.message(4, outgoing: false, at: Self.date(2026, 11, 22, 15, 43, 20)),
            // The same minute a day apart.
            Self.message(5, outgoing: false, at: Self.date(2026, 11, 23, 15, 43, 30)),
        ]
        #expect(Self.times().messagesShowingTime(in: messages) == Set((1...5).map { MessageID($0) }))
    }

    @Test func aMessageSendingOrNotSentShowsNoTimeAndDoesNotHideTheOneBefore() {
        let messages = [
            Self.message(1, outgoing: true, at: Self.date(2026, 11, 22, 15, 42, 5)),
            Self.message(2, outgoing: true, at: Self.date(2026, 11, 22, 15, 42, 10), sendState: .pending),
            Self.message(3, outgoing: true, at: Self.date(2026, 11, 22, 15, 42, 15)),
            Self.message(4, outgoing: true, at: Self.date(2026, 11, 22, 15, 42, 20), sendState: .failed("Network")),
        ]
        #expect(Self.times().messagesShowingTime(in: messages) == [MessageID(1), MessageID(3)])
    }

    @Test func aMessageWithoutADateShowsNoTime() {
        let messages = [
            Self.message(1, outgoing: false, at: Self.date(2026, 11, 22, 15, 42)),
            Self.message(2, outgoing: false, at: Date(timeIntervalSince1970: 0)),
        ]
        #expect(Self.times().messagesShowingTime(in: messages) == [MessageID(1)])
        #expect(Self.times().messagesShowingTime(in: []).isEmpty)
    }

    // MARK: - The times a pull shows (iOS)

    @Test func aPullShowsEachSentMessagesOwnTimeEvenInARun() {
        let first = Self.date(2026, 11, 22, 15, 42, 5)
        let second = Self.date(2026, 11, 22, 15, 42, 20)
        let messages = [
            Self.message(1, outgoing: true, at: first),
            Self.message(2, outgoing: true, at: second),
        ]
        // Under the bubbles only the run's last shows a time.
        #expect(Self.times().messagesShowingTime(in: messages) == [MessageID(2)])
        #expect(Self.times().pulledCaption(for: messages[0]) == Self.times().caption(for: messages[0]))
        #expect(Self.times().pulledCaption(for: messages[1]) == Self.times().caption(for: messages[1]))
        let older = Self.message(3, outgoing: false, at: Self.date(2025, 11, 19, 15, 42))
        #expect(Self.times().pulledCaption(for: older)?.text == Self.times().text(for: older.date))
    }

    @Test func aPullShowsNoTimeForAMessageSendingNotSentOrWithoutADate() {
        let date = Self.date(2026, 11, 22, 15, 42)
        #expect(Self.times().pulledCaption(for: Self.message(1, outgoing: true, at: date, sendState: .pending)) == nil)
        #expect(Self.times().pulledCaption(for: Self.message(2, outgoing: true, at: date, sendState: .failed("Network"))) == nil)
        #expect(Self.times().pulledCaption(for: Self.message(3, outgoing: false, at: Date(timeIntervalSince1970: 0))) == nil)
    }

    // MARK: - VoiceOver

    @Test func voiceOverHearsEachPulledTimeWithItsBubble() {
        let today = Self.date(2026, 11, 22, 15, 42)
        let sent = Self.times().pulledCaption(for: Self.message(1, outgoing: true, at: today))
        #expect(sent?.accessibilityLabel == "Sent \(Self.times().text(for: today))")
        let lastYear = Self.date(2025, 11, 19, 15, 42)
        let received = Self.times().pulledCaption(for: Self.message(2, outgoing: false, at: lastYear))
        #expect(received?.accessibilityLabel == "Received \(Self.times().text(for: lastYear))")
    }

    @Test func voiceOverHearsWhoSentItAndWhen() {
        let today = Self.date(2026, 11, 22, 15, 42)
        let sent = Self.times().caption(for: Self.message(1, outgoing: true, at: today))
        #expect(sent.text == Self.times().text(for: today))
        #expect(sent.accessibilityLabel == "Sent \(sent.text)")
        let nov19 = Self.date(2026, 11, 19, 15, 42)
        let received = Self.times().caption(for: Self.message(2, outgoing: false, at: nov19))
        #expect(received.text == Self.times().text(for: nov19))
        #expect(received.accessibilityLabel == "Received \(received.text)")
    }
}
