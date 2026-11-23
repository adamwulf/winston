#if DEBUG
import SwiftUI
import TelegramLink
import WinstonCore

/// Sample data so the screens preview without TDLib.
extension AppModel {
    static func preview(authState: AuthState = .ready) -> AppModel {
        let home = BotChat(id: ChatID(1), title: "Home", username: "home_bot")
        let laptop = BotChat(id: ChatID(2), title: "Laptop", username: "laptop_bot")
        let start = Date.now.addingTimeInterval(-600)

        func message(
            _ id: Int64,
            in chat: BotChat,
            outgoing: Bool,
            _ text: String,
            attachment: Attachment? = nil,
            reactions: [Reaction] = [],
            sendState: SendState = .sent,
            date: Date? = nil
        ) -> ChatMessage {
            ChatMessage(
                id: MessageID(id),
                chatID: chat.id,
                isOutgoing: outgoing,
                date: date ?? start.addingTimeInterval(Double(id) * 30),
                text: text,
                attachment: attachment,
                reactions: reactions,
                sendState: sendState
            )
        }

        // Earlier days, for the days' headers: across a New Year at least ten days back (so before
        // the days below), then a week, three days and one day ago.
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        func day(_ daysAgo: Int, at hour: Int, from day: Date = today) -> Date {
            let date = calendar.date(byAdding: .day, value: -daysAgo, to: day)!
            return calendar.date(bySettingHour: hour, minute: 15, second: 0, of: date)!
        }
        var newYear = calendar.dateInterval(of: .year, for: .now)!.start
        if calendar.dateComponents([.day], from: newYear, to: today).day! < 10 {
            newYear = calendar.date(byAdding: .year, value: -1, to: newYear)!
        }
        let earlierMessages = [
            message(101, in: home, outgoing: true, "Is the nightly still running?", date: day(1, at: 22, from: newYear)),
            message(102, in: home, outgoing: false, "Yes, it finishes after midnight.", date: day(1, at: 23, from: newYear)),
            message(103, in: home, outgoing: false, "Happy New Year! The nightly passed.", date: day(0, at: 0, from: newYear)),
            message(104, in: home, outgoing: true, "Turn the heating down tonight.", date: day(7, at: 19)),
            message(105, in: home, outgoing: false, "Done: 17°C from 10 PM.", date: day(7, at: 19)),
            message(106, in: home, outgoing: true, "Did the backup run?", date: day(3, at: 8)),
            message(107, in: home, outgoing: false, "It finished at 2:40 with no errors.", date: day(3, at: 8)),
            message(108, in: home, outgoing: false, "The front door was left unlocked.", date: day(1, at: 21)),
        ]

        let homeMessages = earlierMessages + [
            message(1, in: home, outgoing: true, "What's on the build server today?"),
            message(2, in: home, outgoing: false, "Two jobs are queued. The nightly finished at 3:12 with all tests passing.",
                    reactions: [Reaction(emoji: "👍", count: 1, isChosen: true)]),
            message(3, in: home, outgoing: true, "🎙️ mark that read (alt: mark that red)",
                    reactions: [Reaction(emoji: "👀", count: 1, isChosen: false)]),
            message(4, in: home, outgoing: false, "Here's the report.",
                    attachment: .document(FileRef(id: 10, localPath: nil), fileName: "nightly-report.txt",
                                          mimeType: "text/plain", size: 18_432)),
            message(5, in: home, outgoing: false, "",
                    attachment: .photo(FileRef(id: 11, localPath: nil), width: 1600, height: 1200)),
            message(6, in: home, outgoing: true, "/compact", sendState: .pending),
            message(7, in: home, outgoing: true, "Thanks!", sendState: .failed("Network unreachable")),
        ]
        let laptopMessages = [
            message(8, in: laptop, outgoing: false, "The coordinator is offline. Start the coordinator? (y/n)"),
        ]

        return AppModel(
            previewChats: [home, laptop],
            messages: [home.id: homeMessages, laptop.id: laptopMessages],
            authState: authState
        )
    }
}

#Preview("Chat") {
    ChatScreen()
        .environment(AppModel.preview())
        .environment(Presentations())
}

#Preview("Login: phone") {
    LoginView()
        .environment(AppModel.preview(authState: .needsPhoneNumber))
}

#Preview("Login: password") {
    LoginView()
        .environment(AppModel.preview(authState: .needsPassword(hint: "first dog")))
}

#Preview("Settings") {
    SettingsView()
        .environment(AppModel.preview())
}

#Preview("Missing credentials") {
    MissingCredentialsView()
}
#endif
