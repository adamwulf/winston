import Foundation
@preconcurrency import TDLibKit

/// The TDLib requests `TelegramLink` makes, with the signatures TDLibKit generates, so
/// `TDLibClient` conforms as it is. Tests supply a fake in its place: the actor, the update
/// decoding and the mapping all run for real, and only TDLib itself is missing.
package protocol TDLibRequests: Sendable {
    /// Encodes queries with the snake_case keys TDLib expects.
    var encoder: JSONEncoder { get }
    /// Runs a synchronous TDLib request.
    func execute(query: TdQuery) throws -> [String: Any]?

    @discardableResult
    func setTdlibParameters(
        apiHash: String?,
        apiId: Int?,
        applicationVersion: String?,
        databaseDirectory: String?,
        databaseEncryptionKey: Data?,
        deviceModel: String?,
        filesDirectory: String?,
        systemLanguageCode: String?,
        systemVersion: String?,
        useChatInfoDatabase: Bool?,
        useFileDatabase: Bool?,
        useMessageDatabase: Bool?,
        useSecretChats: Bool?,
        useTestDc: Bool?
    ) async throws -> Ok
    @discardableResult
    func setAuthenticationPhoneNumber(
        phoneNumber: String?,
        settings: PhoneNumberAuthenticationSettings?
    ) async throws -> Ok
    @discardableResult
    func checkAuthenticationCode(code: String?) async throws -> Ok
    @discardableResult
    func checkAuthenticationPassword(password: String?) async throws -> Ok
    @discardableResult
    func logOut() async throws -> Ok

    @discardableResult
    func loadChats(chatList: ChatList?, limit: Int?) async throws -> Ok
    func getChats(chatList: ChatList?, limit: Int?) async throws -> Chats
    func getChat(chatId: Int64?) async throws -> Chat
    func getUser(userId: Int64?) async throws -> User
    func getChatHistory(
        chatId: Int64?,
        fromMessageId: Int64?,
        limit: Int?,
        offset: Int?,
        onlyLocal: Bool?
    ) async throws -> Messages
    func getMessage(chatId: Int64?, messageId: Int64?) async throws -> Message

    @discardableResult
    func sendMessage(
        chatId: Int64?,
        inputMessageContent: InputMessageContent?,
        options: MessageSendOptions?,
        replyMarkup: ReplyMarkup?,
        replyTo: InputMessageReplyTo?,
        topicId: MessageTopic?
    ) async throws -> Message
    @discardableResult
    func addMessageReaction(
        chatId: Int64?,
        isBig: Bool?,
        messageId: Int64?,
        reactionType: ReactionType?,
        updateRecentReactions: Bool?
    ) async throws -> Ok
    @discardableResult
    func removeMessageReaction(
        chatId: Int64?,
        messageId: Int64?,
        reactionType: ReactionType?
    ) async throws -> Ok
    @discardableResult
    func viewMessages(
        chatId: Int64?,
        forceRead: Bool?,
        messageIds: [Int64]?,
        source: MessageSource?
    ) async throws -> Ok
    func downloadFile(
        fileId: Int?,
        limit: Int64?,
        offset: Int64?,
        priority: Int?,
        synchronous: Bool?
    ) async throws -> File
}

/// Where `TelegramLink` gets its TDLib clients: `TDLibClientManager` in the app.
package protocol TDLibClientSource {
    /// A new client. `updateHandler` gets each update TDLib sends it, as JSON, in order.
    func makeClient(updateHandler: @escaping @Sendable (Data) -> Void) -> any TDLibRequests
    /// Closes every client, blocking until TDLib reports them closed.
    func closeClients()
}

// `TDLibClient` is safe to share: requests go through its own dispatch queues and a concurrent
// dictionary. TDLibKit predates Swift concurrency, so it doesn't say so itself.
extension TDLibClient: @retroactive @unchecked Sendable, TDLibRequests {}

extension TDLibClientManager: TDLibClientSource {
    package func makeClient(updateHandler: @escaping @Sendable (Data) -> Void) -> any TDLibRequests {
        createClient { data, _ in updateHandler(data) }
    }
}
