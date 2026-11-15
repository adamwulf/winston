import Foundation

/// Navigation information from Telegram's ordinary, unencrypted APNs payload.
/// Its peer fields are at the top level, unlike the FCM `data.custom` format.
/// Winston opens only private bot chats; group and secret-chat alerts still open the app.
public struct TelegramNotification: Equatable, Sendable {
    public let chatID: ChatID
    public let accountID: Int64?

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
    }

    private static func identifier(_ value: Any?) -> Int64? {
        if let string = value as? String { return Int64(string) }
        if let number = value as? NSNumber { return Int64(number.stringValue) }
        return nil
    }
}
