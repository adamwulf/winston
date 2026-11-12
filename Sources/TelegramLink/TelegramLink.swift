import Foundation
import TDLibKit

/// A Telegram user-client session for talking to Adam's bots.
///
/// Wraps TDLibKit and exposes only the plain value types in `Models.swift`.
/// The app never touches TDLibKit types directly.
///
/// `authStates` and `events` are single-consumer streams created once per instance.
public actor TelegramLink {
    public nonisolated let authStates: AsyncStream<AuthState>
    public nonisolated let events: AsyncStream<ChatEvent>

    private let config: TelegramConfig
    private let authContinuation: AsyncStream<AuthState>.Continuation
    private let eventContinuation: AsyncStream<ChatEvent>.Continuation

    public init(config: TelegramConfig) {
        self.config = config
        (authStates, authContinuation) = AsyncStream.makeStream(of: AuthState.self)
        (events, eventContinuation) = AsyncStream.makeStream(of: ChatEvent.self)
    }

    /// Creates the TDLib client and starts the login state machine. Watch `authStates`.
    public func start() async throws {
        throw TelegramLinkError.notImplemented
    }

    // MARK: - Login

    public func submitPhoneNumber(_ phoneNumber: String) async throws {
        throw TelegramLinkError.notImplemented
    }

    public func submitCode(_ code: String) async throws {
        throw TelegramLinkError.notImplemented
    }

    public func submitPassword(_ password: String) async throws {
        throw TelegramLinkError.notImplemented
    }

    public func logOut() async throws {
        throw TelegramLinkError.notImplemented
    }

    // MARK: - Chats and messages

    /// Adam's private chats whose peer is a bot.
    public func botChats() async throws -> [BotChat] {
        throw TelegramLinkError.notImplemented
    }

    /// The most recent messages in a chat, oldest first.
    public func history(in chat: ChatID, limit: Int) async throws -> [ChatMessage] {
        throw TelegramLinkError.notImplemented
    }

    public func sendText(_ text: String, to chat: ChatID) async throws {
        throw TelegramLinkError.notImplemented
    }

    public func sendPhoto(fileURL: URL, caption: String?, to chat: ChatID) async throws {
        throw TelegramLinkError.notImplemented
    }

    /// Adds `emoji` to the message if Adam hasn't reacted with it, otherwise removes it.
    public func toggleReaction(_ emoji: String, on message: MessageID, in chat: ChatID) async throws {
        throw TelegramLinkError.notImplemented
    }

    /// Downloads a file (if needed) and returns its local URL.
    public func downloadFile(_ file: FileRef) async throws -> URL {
        throw TelegramLinkError.notImplemented
    }

    /// Marks messages as read so other Telegram apps don't show stale unread badges.
    public func markRead(_ messages: [MessageID], in chat: ChatID) async throws {
        throw TelegramLinkError.notImplemented
    }
}
