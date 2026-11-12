import Testing
@testable import TelegramLink

@Test func messageIDsOrderByRawValue() {
    #expect(MessageID(1) < MessageID(2))
}
