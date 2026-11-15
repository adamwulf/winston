import Foundation
import Testing
import TelegramLink

struct TelegramNotificationTests {
    @Test func regularAPNsPrivateMessage() throws {
        let payload: [AnyHashable: Any] = [
            "from_id": "1234567890123", "msg_id": "42",
            "aps": ["thread-id": "1234567890123", "alert": ["title": "Bot", "body": "Done"]],
        ]
        let notification = try #require(TelegramNotification(userInfo: payload))
        #expect(notification.chatID == ChatID(1234567890123))
        #expect(notification.accountID == nil)
    }

    @Test func accountIdentifierCanBeAStringOrNumber() throws {
        for account: Any in ["999", NSNumber(value: 999)] {
            let notification = try #require(TelegramNotification(userInfo: ["from_id": "5", "user_id": account]))
            #expect(notification.accountID == 999)
        }
    }

    @Test func groupAndSecretChatAlertsDoNotOpenTheSendersPrivateChat() {
        #expect(TelegramNotification(userInfo: ["from_id": "5", "chat_id": "6"]) == nil)
        #expect(TelegramNotification(userInfo: ["from_id": "5", "channel_id": "6"]) == nil)
        #expect(TelegramNotification(userInfo: ["from_id": "5", "encryption_id": "6"]) == nil)
        #expect(TelegramNotification(userInfo: ["from_id": "5", "aps": ["thread-id": "6"]]) == nil)
    }

    @Test func missingOrInvalidPeerDoesNotNavigate() {
        #expect(TelegramNotification(userInfo: ["aps": ["alert": "New message"]]) == nil)
        #expect(TelegramNotification(userInfo: ["from_id": "not-an-id"]) == nil)
        #expect(TelegramNotification(userInfo: ["from_id": "-1"]) == nil)
    }
}
