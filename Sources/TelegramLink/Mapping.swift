import Foundation
import TDLibKit

/// Pure conversions from TDLibKit types to the public value types in `Models.swift`.
/// Internal so the tests can build TDLibKit values and check the results.
enum Mapping {

    static func chatMessage(_ message: Message) -> ChatMessage {
        let body = body(of: message.content)
        return ChatMessage(
            id: MessageID(message.id),
            chatID: ChatID(message.chatId),
            isOutgoing: message.isOutgoing,
            date: Date(timeIntervalSince1970: TimeInterval(message.date)),
            text: body.text,
            attachment: body.attachment,
            reactions: reactions(message.interactionInfo),
            sendState: sendState(message.sendingState)
        )
    }

    /// The plain text (or caption) and attachment of a message. Content the app doesn't
    /// show becomes a short bracketed placeholder such as `[sticker]`.
    static func body(of content: MessageContent) -> (text: String, attachment: Attachment?) {
        switch content {
        case .messageText(let text):
            return (text.text.text, nil)
        case .messagePhoto(let photo):
            let largest = photo.photo.sizes.max { $0.width * $0.height < $1.width * $1.height }
            guard let largest else { return (photo.caption.text, nil) }
            return (
                photo.caption.text,
                .photo(fileRef(largest.photo), width: largest.width, height: largest.height)
            )
        case .messageDocument(let document):
            let file = document.document.document
            return (
                document.caption.text,
                .document(
                    fileRef(file),
                    fileName: document.document.fileName,
                    mimeType: document.document.mimeType,
                    size: file.size != 0 ? file.size : file.expectedSize
                )
            )
        case .messageAnimatedEmoji(let emoji):
            // TDLib turns a message that is a single emoji into an animated emoji.
            return (emoji.emoji, nil)
        case .messageSticker:
            return ("[sticker]", nil)
        case .messageVoiceNote, .messageExpiredVoiceNote:
            return ("[voice message]", nil)
        case .messageVideoNote, .messageExpiredVideoNote:
            return ("[video message]", nil)
        case .messageAudio:
            return ("[audio]", nil)
        case .messageVideo, .messageExpiredVideo:
            return ("[video]", nil)
        case .messageExpiredPhoto:
            return ("[photo]", nil)
        case .messageAnimation:
            return ("[GIF]", nil)
        case .messageLocation, .messageLiveLocation, .messageVenue:
            return ("[location]", nil)
        case .messageContact:
            return ("[contact]", nil)
        case .messagePoll:
            return ("[poll]", nil)
        default:
            return ("[unsupported message]", nil)
        }
    }

    /// Emoji reactions only. Custom-emoji and paid reactions are skipped.
    static func reactions(_ info: MessageInteractionInfo?) -> [Reaction] {
        guard let reactions = info?.reactions?.reactions else { return [] }
        return reactions.compactMap { reaction in
            guard case .reactionTypeEmoji(let type) = reaction.type else { return nil }
            return Reaction(emoji: type.emoji, count: reaction.totalCount, isChosen: reaction.isChosen)
        }
    }

    static func sendState(_ state: MessageSendingState?) -> SendState {
        switch state {
        case nil:
            return .sent
        case .messageSendingStatePending:
            return .pending
        case .messageSendingStateFailed(let failed):
            return .failed(failed.error.message)
        }
    }

    static func fileRef(_ file: File) -> FileRef {
        let local = file.local
        let isDownloaded = local.isDownloadingCompleted && !local.path.isEmpty
        return FileRef(id: Int32(file.id), localPath: isDownloaded ? local.path : nil)
    }

    static func authState(_ state: AuthorizationState) -> AuthState {
        switch state {
        case .authorizationStateWaitTdlibParameters:
            return .starting
        case .authorizationStateWaitPhoneNumber:
            return .needsPhoneNumber
        case .authorizationStateWaitCode:
            return .needsCode
        case .authorizationStateWaitPassword(let wait):
            return .needsPassword(hint: wait.passwordHint)
        case .authorizationStateReady:
            return .ready
        case .authorizationStateLoggingOut, .authorizationStateClosing:
            return .loggingOut
        case .authorizationStateClosed:
            return .closed
        case .authorizationStateWaitPremiumPurchase:
            return .unsupported("authorizationStateWaitPremiumPurchase")
        case .authorizationStateWaitEmailAddress:
            return .unsupported("authorizationStateWaitEmailAddress")
        case .authorizationStateWaitEmailCode:
            return .unsupported("authorizationStateWaitEmailCode")
        case .authorizationStateWaitOtherDeviceConfirmation:
            return .unsupported("authorizationStateWaitOtherDeviceConfirmation")
        case .authorizationStateWaitRegistration:
            return .unsupported("authorizationStateWaitRegistration")
        }
    }

    /// A `BotChat` when `chat` is a private chat with `user` and `user` is a bot.
    static func botChat(chat: Chat, user: User) -> BotChat? {
        guard case .chatTypePrivate(let info) = chat.type, info.userId == user.id,
              case .userTypeBot = user.type
        else { return nil }
        return BotChat(id: ChatID(chat.id), title: chat.title, username: user.usernames?.activeUsernames.first)
    }
}
