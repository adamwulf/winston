#if DEBUG
import SwiftUI
import TelegramLink

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
            sendState: SendState = .sent
        ) -> ChatMessage {
            ChatMessage(
                id: MessageID(id),
                chatID: chat.id,
                isOutgoing: outgoing,
                date: start.addingTimeInterval(Double(id) * 30),
                text: text,
                attachment: attachment,
                reactions: reactions,
                sendState: sendState
            )
        }

        let homeMessages = [
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
