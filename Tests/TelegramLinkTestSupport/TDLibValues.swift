import Foundation
import TDLibKit

// Builders for the TDLibKit values the tests feed to TelegramLink. TDLibKit's own initializers
// take every field; these fill in the ones the app doesn't read.

package func formatted(_ text: String) -> FormattedText {
    FormattedText(entities: [], text: text)
}

package func file(id: Int, size: Int64 = 0, expectedSize: Int64 = 0, downloadedPath: String? = nil) -> File {
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

package func photoSize(fileID: Int, width: Int, height: Int, downloadedPath: String? = nil) -> PhotoSize {
    PhotoSize(
        height: height,
        photo: file(id: fileID, downloadedPath: downloadedPath),
        progressiveSizes: [],
        type: "x",
        width: width
    )
}

package func messageReaction(_ type: ReactionType, count: Int, isChosen: Bool) -> MessageReaction {
    MessageReaction(isChosen: isChosen, recentSenderIds: [], totalCount: count, type: type, usedSenderId: nil)
}

package func interactionInfo(_ reactions: [MessageReaction]) -> MessageInteractionInfo {
    MessageInteractionInfo(
        forwardCount: 0,
        reactions: MessageReactions(areTags: false, canGetAddedReactions: false, paidReactors: [], reactions: reactions),
        replyInfo: nil,
        viewCount: 0
    )
}

package func botType() -> UserTypeBot {
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

package func user(id: Int64, type: UserType, username: String) -> User {
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

package func chat(id: Int64, title: String, type: ChatType) -> Chat {
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

package func makeMessage(
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

/// A plain text message.
package func textMessage(
    id: Int64,
    chatID: Int64,
    isOutgoing: Bool = false,
    date: Int = 0,
    _ text: String,
    interactionInfo: MessageInteractionInfo? = nil,
    sendingState: MessageSendingState? = nil
) -> Message {
    makeMessage(
        id: id,
        chatID: chatID,
        isOutgoing: isOutgoing,
        date: date,
        content: .messageText(MessageText(linkPreview: nil, linkPreviewOptions: nil, text: formatted(text))),
        interactionInfo: interactionInfo,
        sendingState: sendingState
    )
}

/// A private chat with a bot, and the bot's user, sharing `id`.
package func botChat(id: Int64, title: String, username: String) -> (chat: Chat, user: User) {
    (
        chat(id: id, title: title, type: .chatTypePrivate(ChatTypePrivate(userId: id))),
        user(id: id, type: .userTypeBot(botType()), username: username)
    )
}
