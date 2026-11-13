import Foundation
import TDLibKit
import Testing
@testable import TelegramLink

@Test func messageIDsOrderByRawValue() {
    #expect(MessageID(1) < MessageID(2))
}

// MARK: - Message content

@Test func textMessageMapsToPlainText() {
    let message = makeMessage(
        id: 42,
        chatID: 7,
        isOutgoing: true,
        date: 1_700_000_000,
        content: .messageText(MessageText(linkPreview: nil, linkPreviewOptions: nil, text: formatted("hello")))
    )

    let mapped = Mapping.chatMessage(message)

    #expect(mapped.id == MessageID(42))
    #expect(mapped.chatID == ChatID(7))
    #expect(mapped.isOutgoing)
    #expect(mapped.date == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(mapped.text == "hello")
    #expect(mapped.attachment == nil)
    #expect(mapped.reactions.isEmpty)
    #expect(mapped.sendState == .sent)
}

@Test func photoMessageUsesLargestSizeAndCaption() {
    let photo = Photo(
        hasStickers: false,
        minithumbnail: nil,
        sizes: [
            photoSize(fileID: 1, width: 90, height: 60),
            photoSize(fileID: 3, width: 1280, height: 853, downloadedPath: "/tmp/big.jpg"),
            photoSize(fileID: 2, width: 320, height: 213),
        ]
    )
    let content = MessageContent.messagePhoto(MessagePhoto(
        caption: formatted("a cat"),
        hasSpoiler: false,
        isSecret: false,
        photo: photo,
        showCaptionAboveMedia: false,
        video: nil
    ))

    let body = Mapping.body(of: content)

    #expect(body.text == "a cat")
    #expect(body.attachment == .photo(FileRef(id: 3, localPath: "/tmp/big.jpg"), width: 1280, height: 853))
}

@Test func documentMessageMapsFileDetailsAndCaption() {
    let document = Document(
        document: file(id: 9, size: 2048),
        fileName: "report.pdf",
        mimeType: "application/pdf",
        minithumbnail: nil,
        thumbnail: nil
    )
    let content = MessageContent.messageDocument(MessageDocument(caption: formatted("see this"), document: document))

    let body = Mapping.body(of: content)

    #expect(body.text == "see this")
    #expect(body.attachment == .document(
        FileRef(id: 9, localPath: nil),
        fileName: "report.pdf",
        mimeType: "application/pdf",
        size: 2048
    ))
}

@Test func documentSizeFallsBackToExpectedSize() {
    let document = Document(
        document: file(id: 9, size: 0, expectedSize: 4096),
        fileName: "log.txt",
        mimeType: "text/plain",
        minithumbnail: nil,
        thumbnail: nil
    )

    let body = Mapping.body(of: .messageDocument(MessageDocument(caption: formatted(""), document: document)))

    #expect(body.attachment == .document(FileRef(id: 9, localPath: nil), fileName: "log.txt", mimeType: "text/plain", size: 4096))
}

@Test func unsupportedContentBecomesBracketedPlaceholder() {
    let voiceNote = MessageContent.messageVoiceNote(MessageVoiceNote(
        caption: formatted(""),
        isListened: false,
        voiceNote: VoiceNote(duration: 3, mimeType: "audio/ogg", speechRecognitionResult: nil, voice: file(id: 5), waveform: Data())
    ))

    #expect(Mapping.body(of: voiceNote).text == "[voice message]")
    #expect(Mapping.body(of: voiceNote).attachment == nil)
    #expect(Mapping.body(of: .messageExpiredPhoto).text == "[photo]")
    #expect(Mapping.body(of: .messageUnsupported).text == "[unsupported message]")
    #expect(Mapping.body(of: .messageContactRegistered).text == "[unsupported message]")
}

@Test func singleEmojiMessageKeepsItsEmoji() {
    let animated = AnimatedEmoji(
        fitzpatrickType: 0,
        isRegularEmoji: true,
        sound: nil,
        sticker: nil,
        stickerHeight: 0,
        stickerWidth: 0
    )

    let body = Mapping.body(of: .messageAnimatedEmoji(MessageAnimatedEmoji(animatedEmoji: animated, emoji: "👍")))

    #expect(body.text == "👍")
    #expect(body.attachment == nil)
}

// MARK: - Reactions

@Test func reactionsMapEmojiCountAndChosen() {
    let info = interactionInfo([
        messageReaction(.reactionTypeEmoji(ReactionTypeEmoji(emoji: "👍")), count: 1, isChosen: true),
        messageReaction(.reactionTypeEmoji(ReactionTypeEmoji(emoji: "👀")), count: 2, isChosen: false),
    ])

    #expect(Mapping.reactions(info) == [
        Reaction(emoji: "👍", count: 1, isChosen: true),
        Reaction(emoji: "👀", count: 2, isChosen: false),
    ])
}

@Test func reactionsSkipCustomEmojiAndPaid() {
    let info = interactionInfo([
        messageReaction(.reactionTypeCustomEmoji(ReactionTypeCustomEmoji(customEmojiId: 12345)), count: 1, isChosen: false),
        messageReaction(.reactionTypePaid, count: 5, isChosen: false),
        messageReaction(.reactionTypeEmoji(ReactionTypeEmoji(emoji: "🔥")), count: 1, isChosen: false),
    ])

    #expect(Mapping.reactions(info) == [Reaction(emoji: "🔥", count: 1, isChosen: false)])
}

@Test func missingInteractionInfoMeansNoReactions() {
    #expect(Mapping.reactions(nil).isEmpty)
    let noReactions = MessageInteractionInfo(forwardCount: 0, reactions: nil, replyInfo: nil, viewCount: 0)
    #expect(Mapping.reactions(noReactions).isEmpty)
}

@Test func messageCarriesItsReactions() {
    let message = makeMessage(
        content: .messageText(MessageText(linkPreview: nil, linkPreviewOptions: nil, text: formatted("hi"))),
        interactionInfo: interactionInfo([
            messageReaction(.reactionTypeEmoji(ReactionTypeEmoji(emoji: "👍")), count: 1, isChosen: true),
        ])
    )

    #expect(Mapping.chatMessage(message).reactions == [Reaction(emoji: "👍", count: 1, isChosen: true)])
}

// MARK: - Send states

@Test func sendStatesMap() {
    #expect(Mapping.sendState(nil) == .sent)
    #expect(Mapping.sendState(.messageSendingStatePending(MessageSendingStatePending(sendingId: 0))) == .pending)

    let failed = MessageSendingStateFailed(
        canRetry: false,
        error: TDLibKit.Error(code: 400, message: "PEER_ID_INVALID"),
        needAnotherReplyQuote: false,
        needAnotherSender: false,
        needDropReply: false,
        requiredPaidMessageStarCount: 0,
        retryAfter: 0
    )
    #expect(Mapping.sendState(.messageSendingStateFailed(failed)) == .failed("PEER_ID_INVALID"))
}

@Test func pendingOutgoingMessageIsPending() {
    let message = makeMessage(
        isOutgoing: true,
        content: .messageText(MessageText(linkPreview: nil, linkPreviewOptions: nil, text: formatted("sending"))),
        sendingState: .messageSendingStatePending(MessageSendingStatePending(sendingId: 0))
    )

    #expect(Mapping.chatMessage(message).sendState == .pending)
}

// MARK: - Auth states

@Test func authStatesMap() {
    #expect(Mapping.authState(.authorizationStateWaitTdlibParameters) == .starting)
    #expect(Mapping.authState(.authorizationStateWaitPhoneNumber) == .needsPhoneNumber)
    #expect(Mapping.authState(.authorizationStateReady) == .ready)
    #expect(Mapping.authState(.authorizationStateLoggingOut) == .loggingOut)
    #expect(Mapping.authState(.authorizationStateClosing) == .loggingOut)
    #expect(Mapping.authState(.authorizationStateClosed) == .closed)

    let password = AuthorizationStateWaitPassword(
        hasPassportData: false,
        hasRecoveryEmailAddress: false,
        passwordHint: "dog",
        recoveryEmailAddressPattern: ""
    )
    #expect(Mapping.authState(.authorizationStateWaitPassword(password)) == .needsPassword(hint: "dog"))

    let email = AuthorizationStateWaitEmailAddress(allowAppleId: false, allowGoogleId: false)
    #expect(Mapping.authState(.authorizationStateWaitEmailAddress(email)) == .unsupported("authorizationStateWaitEmailAddress"))
}

// MARK: - Bot chats

@Test func privateChatWithBotMapsToBotChat() {
    let bot = user(id: 5, type: .userTypeBot(botType()), username: "winston_bot")
    let chat = chat(id: 5, title: "Winston", type: .chatTypePrivate(ChatTypePrivate(userId: 5)))

    #expect(Mapping.botChat(chat: chat, user: bot) == BotChat(id: ChatID(5), title: "Winston", username: "winston_bot"))
}

@Test func privateChatWithPersonIsNotABotChat() {
    let person = user(id: 6, type: .userTypeRegular, username: "adam")
    let chat = chat(id: 6, title: "Adam", type: .chatTypePrivate(ChatTypePrivate(userId: 6)))

    #expect(Mapping.botChat(chat: chat, user: person) == nil)
}

// MARK: - Builders

private func formatted(_ text: String) -> FormattedText {
    FormattedText(entities: [], text: text)
}

private func file(id: Int, size: Int64 = 0, expectedSize: Int64 = 0, downloadedPath: String? = nil) -> File {
    File(
        expectedSize: expectedSize,
        id: id,
        local: LocalFile(
            canBeDeleted: downloadedPath != nil,
            canBeDownloaded: true,
            downloadOffset: 0,
            downloadedPrefixSize: 0,
            downloadedSize: 0,
            isDownloadingActive: false,
            isDownloadingCompleted: downloadedPath != nil,
            path: downloadedPath ?? ""
        ),
        remote: RemoteFile(id: "", isUploadingActive: false, isUploadingCompleted: true, uniqueId: "", uploadedSize: 0),
        size: size
    )
}

private func photoSize(fileID: Int, width: Int, height: Int, downloadedPath: String? = nil) -> PhotoSize {
    PhotoSize(
        height: height,
        photo: file(id: fileID, downloadedPath: downloadedPath),
        progressiveSizes: [],
        type: "x",
        width: width
    )
}

private func messageReaction(_ type: ReactionType, count: Int, isChosen: Bool) -> MessageReaction {
    MessageReaction(isChosen: isChosen, recentSenderIds: [], totalCount: count, type: type, usedSenderId: nil)
}

private func interactionInfo(_ reactions: [MessageReaction]) -> MessageInteractionInfo {
    MessageInteractionInfo(
        forwardCount: 0,
        reactions: MessageReactions(areTags: false, canGetAddedReactions: false, paidReactors: [], reactions: reactions),
        replyInfo: nil,
        viewCount: 0
    )
}

private func botType() -> UserTypeBot {
    UserTypeBot(
        activeUserCount: 0,
        allowsUsersToCreateTopics: false,
        canBeAddedToAttachmentMenu: false,
        canBeEdited: false,
        canConnectToBusiness: false,
        canJoinGroups: false,
        canManageBots: false,
        canReadAllGroupMessages: false,
        hasMainWebApp: false,
        hasTopicSidebar: false,
        hasTopics: false,
        inlineQueryPlaceholder: "",
        isGuard: false,
        isInline: false,
        needLocation: false,
        supportsGuestQueries: false
    )
}

private func user(id: Int64, type: UserType, username: String) -> User {
    User(
        accentColorId: 0,
        activeStoryState: nil,
        addedToAttachmentMenu: false,
        backgroundCustomEmojiId: 0,
        emojiStatus: nil,
        firstName: "",
        haveAccess: true,
        id: id,
        isCloseFriend: false,
        isContact: false,
        isMutualContact: false,
        isPremium: false,
        isSupport: false,
        languageCode: "",
        lastName: "",
        paidMessageStarCount: 0,
        phoneNumber: "",
        profileAccentColorId: 0,
        profileBackgroundCustomEmojiId: 0,
        profilePhoto: nil,
        restrictionInfo: nil,
        restrictsNewChats: false,
        status: .userStatusEmpty,
        type: type,
        upgradedGiftColors: nil,
        usernames: Usernames(
            activeUsernames: [username],
            collectibleUsernames: [],
            disabledUsernames: [],
            editableUsername: username,
            secondaryUsername: ""
        ),
        verificationStatus: nil
    )
}

private func chat(id: Int64, title: String, type: ChatType) -> Chat {
    Chat(
        accentColorId: 0,
        actionBar: nil,
        availableReactions: .chatAvailableReactionsAll(ChatAvailableReactionsAll(maxReactionCount: 1)),
        background: nil,
        backgroundCustomEmojiId: 0,
        blockList: nil,
        businessBotManageBar: nil,
        canBeDeletedForAllUsers: false,
        canBeDeletedOnlyForSelf: true,
        canBeReported: false,
        chatLists: [.chatListMain],
        clientData: "",
        defaultDisableNotification: false,
        draftMessage: nil,
        emojiStatus: nil,
        hasProtectedContent: false,
        hasScheduledMessages: false,
        hasWelcomeMessages: false,
        id: id,
        isMarkedAsUnread: false,
        isTranslatable: false,
        lastMessage: nil,
        lastReadInboxMessageId: 0,
        lastReadOutboxMessageId: 0,
        messageAutoDeleteTime: 0,
        messageSenderId: nil,
        notificationSettings: ChatNotificationSettings(
            disableMentionNotifications: false,
            disablePinnedMessageNotifications: false,
            muteFor: 0,
            muteStories: false,
            showPreview: true,
            showStoryPoster: false,
            soundId: 0,
            storySoundId: 0,
            useDefaultDisableMentionNotifications: true,
            useDefaultDisablePinnedMessageNotifications: true,
            useDefaultMuteFor: true,
            useDefaultMuteStories: true,
            useDefaultShowPreview: true,
            useDefaultShowStoryPoster: true,
            useDefaultSound: true,
            useDefaultStorySound: true
        ),
        pendingJoinRequests: nil,
        permissions: ChatPermissions(
            canAddLinkPreviews: true,
            canChangeInfo: false,
            canCreateTopics: false,
            canEditTag: false,
            canInviteUsers: false,
            canPinMessages: true,
            canReactToMessages: true,
            canSendAudios: true,
            canSendBasicMessages: true,
            canSendDocuments: true,
            canSendOtherMessages: true,
            canSendPhotos: true,
            canSendPolls: true,
            canSendVideoNotes: true,
            canSendVideos: true,
            canSendVoiceNotes: true
        ),
        photo: nil,
        positions: [],
        profileAccentColorId: 0,
        profileBackgroundCustomEmojiId: 0,
        replyMarkupMessageId: 0,
        theme: nil,
        title: title,
        type: type,
        unreadCount: 0,
        unreadMentionCount: 0,
        unreadPollVoteCount: 0,
        unreadReactionCount: 0,
        upgradedGiftColors: nil,
        videoChat: VideoChat(defaultParticipantId: nil, groupCallId: 0, hasParticipants: false),
        viewAsTopics: false
    )
}

private func makeMessage(
    id: Int64 = 1,
    chatID: Int64 = 1,
    isOutgoing: Bool = false,
    date: Int = 0,
    content: MessageContent,
    interactionInfo: MessageInteractionInfo? = nil,
    sendingState: MessageSendingState? = nil
) -> Message {
    Message(
        authorSignature: "",
        autoDeleteIn: 0,
        canBeSaved: true,
        chatId: chatID,
        chatInstance: 0,
        containsUnreadMention: false,
        containsUnreadPollVotes: false,
        content: content,
        date: date,
        editDate: 0,
        effectId: 0,
        ephemeralContent: nil,
        ephemeralMessageId: 0,
        factCheck: nil,
        forwardInfo: nil,
        guestBotCallerId: nil,
        hasTimestampedMedia: false,
        id: id,
        importInfo: nil,
        interactionInfo: interactionInfo,
        isChannelPost: false,
        isFromOffline: false,
        isOutgoing: isOutgoing,
        isPaidGramSuggestedPost: false,
        isPaidStarSuggestedPost: false,
        isPinned: false,
        mediaAlbumId: 0,
        paidMessageStarCount: 0,
        receiverId: nil,
        replyMarkup: nil,
        replyTo: nil,
        restrictionInfo: nil,
        schedulingState: nil,
        selfDestructIn: 0,
        selfDestructType: nil,
        senderBoostCount: 0,
        senderBusinessBotUserId: 0,
        senderId: .messageSenderUser(MessageSenderUser(userId: 1)),
        senderTag: "",
        sendingState: sendingState,
        suggestedPostInfo: nil,
        summaryLanguageCode: "",
        topicId: nil,
        unreadReactions: [],
        viaBotUserId: 0
    )
}
