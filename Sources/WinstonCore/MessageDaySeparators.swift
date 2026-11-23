import Foundation
import TelegramLink

/// The headers in the chat where a new day starts, as in Messages: one above the first message
/// shown, and one above each message on another day than the message before it. Each says the
/// day in the given calendar, time zone and locale (the app passes the user's): "Today",
/// "Yesterday", the weekday for the five days before those, and the date otherwise.
public enum MessageDaySeparators {
    /// One header: the day it shows, and what VoiceOver reads for it.
    public struct Separator: Equatable, Sendable {
        public let text: String
        public let accessibilityLabel: String
    }

    /// The headers for `messages`, a chat's in the order shown, by the ID of the message each goes
    /// above: the first message with a date, and each later one whose day isn't that of the last
    /// message with a date before it.
    ///
    /// - A message without a date (TDLib's 0) has no day. It goes with the messages before it,
    ///   under their header, or under none if no message before it has a date.
    /// - A message still sending, or not sent, is on the day this device tried to send it, so the
    ///   first message of a day shows that day's header as soon as it is sent. One sent across
    ///   midnight moves to the day of the date the server gives it once it is sent.
    /// - Messages out of date order each go under a header for their own day, so a day can show
    ///   twice: each header is the day of the messages under it.
    public static func compute(
        _ messages: [ChatMessage],
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone,
        locale: Locale
    ) -> [MessageID: Separator] {
        let days = Days(now: now, calendar: calendar, timeZone: timeZone, locale: locale)
        var separators: [MessageID: Separator] = [:]
        // Each day's header, made once however often the day shows.
        var made: [Date: Separator] = [:]
        var previousDay: Date?
        for message in messages where hasDay(message) {
            let day = days.calendar.startOfDay(for: message.date)
            guard day != previousDay else { continue }
            previousDay = day
            let separator = made[day] ?? days.separator(forDay: day)
            made[day] = separator
            separators[message.id] = separator
        }
        return separators
    }

    /// The header for the day `date` is on: "Today" or "Yesterday" (the locale's words), the
    /// weekday for the five days before yesterday ("Wednesday"), and otherwise the date ("Tue,
    /// Nov 17"), with the year if it isn't this year ("Mon, Nov 17, 2025"). A day after today, as
    /// from a clock that is ahead, shows its date. The order, spelling and punctuation are the
    /// locale's.
    public static func separator(
        forDayOf date: Date,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone,
        locale: Locale
    ) -> Separator {
        let days = Days(now: now, calendar: calendar, timeZone: timeZone, locale: locale)
        return days.separator(forDay: days.calendar.startOfDay(for: date))
    }

    /// Whether `message` has a date, and so a day.
    private static func hasDay(_ message: ChatMessage) -> Bool {
        message.date.timeIntervalSince1970 > 0
    }

    /// Names days relative to `now`'s.
    private struct Days {
        /// With the time zone and locale set on it.
        let calendar: Calendar
        let now: Date
        /// Noon today, which days are counted back from.
        let todayNoon: Date
        /// Capitalized as a header starts, as the weekday and date are by the locale's rules.
        let style: Date.FormatStyle

        init(now: Date, calendar: Calendar, timeZone: TimeZone, locale: Locale) {
            var calendar = calendar
            calendar.timeZone = timeZone
            calendar.locale = locale
            self.calendar = calendar
            self.now = now
            todayNoon = Self.noon(of: now, in: calendar)
            style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone,
                                     capitalizationContext: .beginningOfSentence)
        }

        /// The header for `day`, the start of a day in `calendar`.
        func separator(forDay day: Date) -> Separator {
            // Noon to noon, which counts whole days even when one is 23 or 25 hours long, as
            // daylight saving time starts or ends. Midnight to midnight counted none from a day
            // that started an hour late (when its midnight was skipped) to the next.
            let daysAgo = calendar.dateComponents([.day], from: Self.noon(of: day, in: calendar), to: todayNoon).day ?? 0
            switch daysAgo {
            case 0, 1:
                // The locale's word for the day, from the number of days alone: unlike
                // DateFormatter's, it doesn't depend on the clock.
                let formatter = RelativeDateTimeFormatter()
                formatter.calendar = calendar
                formatter.locale = calendar.locale
                formatter.dateTimeStyle = .named
                formatter.unitsStyle = .full
                formatter.formattingContext = .beginningOfSentence
                let word = formatter.localizedString(from: DateComponents(day: -daysAgo))
                return Separator(text: word, accessibilityLabel: word)
            case 2...6:
                let weekday = day.formatted(style.weekday(.wide))
                return Separator(text: weekday, accessibilityLabel: weekday)
            default:
                // In full for VoiceOver, which may not expand "Tue" and "Nov".
                if calendar.isDate(day, equalTo: now, toGranularity: .year) {
                    return Separator(text: day.formatted(style.weekday(.abbreviated).month(.abbreviated).day()),
                                     accessibilityLabel: day.formatted(style.weekday(.wide).month(.wide).day()))
                }
                return Separator(text: day.formatted(style.weekday(.abbreviated).month(.abbreviated).day().year()),
                                 accessibilityLabel: day.formatted(style.weekday(.wide).month(.wide).day().year()))
            }
        }

        /// Noon on the day `date` is on.
        private static func noon(of date: Date, in calendar: Calendar) -> Date {
            calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        }
    }
}
