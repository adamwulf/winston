import Foundation
import TelegramLink

/// The times the chat shows under its bubbles: when each message was sent or received, in the
/// given calendar, time zone and locale (the app passes the user's, with their 12- or 24-hour
/// setting). Today's show the time only; older ones the day too.
public struct MessageTimes {
    /// The time under one bubble: the text it shows, and what VoiceOver reads for it.
    public struct Caption: Equatable, Sendable {
        public let text: String
        public let accessibilityLabel: String
    }

    /// The moment "today" and "yesterday" are relative to.
    public let now: Date
    /// With `timeZone` and `locale` set on it.
    private let calendar: Calendar
    private let timeZone: TimeZone
    private let locale: Locale

    public init(now: Date, calendar: Calendar, timeZone: TimeZone, locale: Locale) {
        self.now = now
        var calendar = calendar
        calendar.timeZone = timeZone
        calendar.locale = locale
        self.calendar = calendar
        self.timeZone = timeZone
        self.locale = locale
    }

    /// The messages in `messages`, a chat's in order, whose bubble shows its time. A sent message
    /// shows it unless the next message is from the same side, shows its time too, and was sent in
    /// the same minute: then only the last bubble of that run shows the time, which is theirs too.
    /// A message still sending, or not sent, shows its send state instead (its date is only when
    /// this device tried to send it), and one without a date (TDLib's 0) shows none.
    public func messagesShowingTime(in messages: [ChatMessage]) -> Set<MessageID> {
        var shown = Set<MessageID>()
        for (index, message) in messages.enumerated() where Self.hasTime(message) {
            let next = messages.indices.contains(index + 1) ? messages[index + 1] : nil
            if let next, Self.hasTime(next), next.isOutgoing == message.isOutgoing,
               calendar.isDate(next.date, equalTo: message.date, toGranularity: .minute) {
                continue
            }
            shown.insert(message.id)
        }
        return shown
    }

    /// The time under `message`'s bubble, for one that `messagesShowingTime(in:)` names.
    public func caption(for message: ChatMessage) -> Caption {
        let text = text(for: message.date)
        return Caption(text: text, accessibilityLabel: "\(message.isOutgoing ? "Sent" : "Received") \(text)")
    }

    /// `date` as the chat shows it: the time for today ("3:42 PM", or "15:42" in 24-hour time),
    /// "Yesterday at 3:42 PM", the day and time earlier this year ("Nov 19 at 3:42 PM"), and the
    /// year too before that. The words, order and punctuation are the locale's.
    public func text(for date: Date) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(style.hour().minute())
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            // DateFormatter names the day against the clock rather than `now`. They agree in the
            // app, which sets `now` as the day changes; were it ever stale, this shows the date
            // ("Nov 21, 2026 at 3:42 PM"), which is right too.
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.doesRelativeDateFormatting = true
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(style.month(.abbreviated).day().hour().minute())
        }
        return date.formatted(style.year().month(.abbreviated).day().hour().minute())
    }

    /// Whether `message`'s date is when it was sent: it was, and has one.
    private static func hasTime(_ message: ChatMessage) -> Bool {
        message.sendState == .sent && message.date.timeIntervalSince1970 > 0
    }
}
