import Foundation

/// Navigation information from Telegram's ordinary, unencrypted APNs payload.
/// Its peer fields are at the top level, unlike the FCM `data.custom` format.
/// Winston opens only private bot chats; group and secret-chat alerts still open the app.
public struct TelegramNotification: Equatable, Sendable {
    public let chatID: ChatID
    public let accountID: Int64?
    /// The message the alert announces, as TDLib identifies it, so the logs can match an alert
    /// with the message TDLib later delivers. Nil when the payload has no `msg_id`.
    public let messageID: MessageID?

    public init?(userInfo: [AnyHashable: Any]) {
        guard userInfo["chat_id"] == nil, userInfo["channel_id"] == nil,
              userInfo["encryption_id"] == nil,
              let fromID = Self.identifier(userInfo["from_id"]), fromID > 0 else { return nil }
        // Some group alerts identify the group only with thread-id. Don't mistake their
        // sender for the private chat to open.
        if let aps = userInfo["aps"] as? [String: Any], let thread = aps["thread-id"] {
            guard Self.identifier(thread) == fromID else { return nil }
        }
        chatID = ChatID(fromID)
        // Telegram may omit user_id for a single-account registration.
        accountID = Self.identifier(userInfo["user_id"])
        messageID = Self.identifier(userInfo["msg_id"]).flatMap { Self.tdlibMessageID(serverID: $0) }
    }

    /// TDLib's ID for the server message ID a push carries: TDLib shifts a server ID left by 20
    /// bits (`MessageId::SERVER_ID_SHIFT` in TDLib's `MessageId.h`).
    private static func tdlibMessageID(serverID: Int64) -> MessageID? {
        guard serverID > 0 else { return nil }
        let (shifted, overflow) = serverID.multipliedReportingOverflow(by: 1 << 20)
        return overflow ? nil : MessageID(shifted)
    }

    private static func identifier(_ value: Any?) -> Int64? {
        if let string = value as? String { return Int64(string) }
        if let number = value as? NSNumber { return Int64(number.stringValue) }
        return nil
    }
}
