import Foundation

/// A Telegram chat identifier (TDLib `chat.id`).
public struct ChatID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: Int64
    public init(_ rawValue: Int64) { self.rawValue = rawValue }
    public var description: String { String(rawValue) }
}

/// A Telegram message identifier (TDLib `message.id`). Unique within a chat.
public struct MessageID: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: Int64
    public init(_ rawValue: Int64) { self.rawValue = rawValue }
    public static func < (lhs: MessageID, rhs: MessageID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { String(rawValue) }
}

/// Everything TDLib needs to start a session.
public struct TelegramConfig: Sendable {
    public var apiID: Int32
    public var apiHash: String
    /// Where TDLib keeps its database (messages, chats, session). Persist across launches.
    public var databaseDirectory: URL
    /// Where TDLib keeps downloaded and uploaded files.
    public var filesDirectory: URL
    public var deviceModel: String
    public var systemVersion: String
    public var applicationVersion: String
    public var systemLanguageCode: String

    public init(
        apiID: Int32,
        apiHash: String,
        databaseDirectory: URL,
        filesDirectory: URL,
        deviceModel: String,
        systemVersion: String,
        applicationVersion: String,
        systemLanguageCode: String = Locale.current.language.languageCode?.identifier ?? "en"
    ) {
        self.apiID = apiID
        self.apiHash = apiHash
        self.databaseDirectory = databaseDirectory
        self.filesDirectory = filesDirectory
        self.deviceModel = deviceModel
        self.systemVersion = systemVersion
        self.applicationVersion = applicationVersion
        self.systemLanguageCode = systemLanguageCode
    }
}

/// The login state machine, simplified from TDLib's `AuthorizationState`.
public enum AuthState: Sendable, Equatable {
    /// TDLib is starting up or applying parameters.
    case starting
    case needsPhoneNumber
    /// A login code was sent (usually to Adam's other Telegram apps).
    case needsCode
    /// The account has a 2FA password. `hint` may be empty.
    case needsPassword(hint: String)
    case ready
    case loggingOut
    case closed
    /// A rare TDLib state the app doesn't handle (e.g. email setup). The string names it.
    /// It also carries a startup error, such as "setTdlibParameters failed: …", when the
    /// api_id / api_hash is missing or the database is locked. TDLib only checks here that
    /// they are present (api_id > 0, non-empty hash); a wrong but non-empty value fails later,
    /// as a `TelegramLinkError.tdlib` thrown from `submitPhoneNumber`.
    case unsupported(String)
}

/// A private chat with a bot.
public struct BotChat: Identifiable, Hashable, Sendable {
    public let id: ChatID
    public var title: String
    public var username: String?

    public init(id: ChatID, title: String, username: String?) {
        self.id = id
        self.title = title
        self.username = username
    }
}

/// A TDLib file reference. `localPath` is set once the file is downloaded.
public struct FileRef: Hashable, Sendable {
    public let id: Int32
    public var localPath: String?

    public init(id: Int32, localPath: String?) {
        self.id = id
        self.localPath = localPath
    }
}

public enum Attachment: Hashable, Sendable {
    case photo(FileRef, width: Int, height: Int)
    case document(FileRef, fileName: String, mimeType: String, size: Int64)
}

/// One emoji reaction on a message.
public struct Reaction: Hashable, Sendable {
    public var emoji: String
    public var count: Int
    /// True when Adam (the logged-in user) added this reaction.
    public var isChosen: Bool

    public init(emoji: String, count: Int, isChosen: Bool) {
        self.emoji = emoji
        self.count = count
        self.isChosen = isChosen
    }
}

public enum SendState: Hashable, Sendable {
    case sent
    case pending
    case failed(String)
}

public struct ChatMessage: Identifiable, Hashable, Sendable {
    public let id: MessageID
    public let chatID: ChatID
    public var isOutgoing: Bool
    public var date: Date
    /// Plain text, or the caption for photos/documents. The bots send plain text only.
    public var text: String
    public var attachment: Attachment?
    public var reactions: [Reaction]
    public var sendState: SendState

    public init(
        id: MessageID,
        chatID: ChatID,
        isOutgoing: Bool,
        date: Date,
        text: String,
        attachment: Attachment? = nil,
        reactions: [Reaction] = [],
        sendState: SendState = .sent
    ) {
        self.id = id
        self.chatID = chatID
        self.isOutgoing = isOutgoing
        self.date = date
        self.text = text
        self.attachment = attachment
        self.reactions = reactions
        self.sendState = sendState
    }
}

public enum ChatEvent: Sendable {
    /// A new message in any chat, incoming or outgoing (outgoing ones start as `.pending`).
    case newMessage(ChatMessage)
    /// The reactions on a message changed.
    case reactionsChanged(chat: ChatID, message: MessageID, reactions: [Reaction])
    /// The bot started or stopped "typing". TDLib actions expire after about 5 seconds.
    case typing(chat: ChatID, isTyping: Bool)
    /// A pending outgoing message was accepted by the server and got its final ID.
    case sendSucceeded(chat: ChatID, oldID: MessageID, message: ChatMessage)
    /// A pending outgoing message failed to send. `message` is its temporary (pending) ID.
    case sendFailed(chat: ChatID, message: MessageID, error: String)
}

public enum TelegramLinkError: Error, Sendable, Equatable {
    case notStarted
    case notImplemented
    case tdlib(code: Int, message: String)
}
