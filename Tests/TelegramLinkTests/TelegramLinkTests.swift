import Foundation
import TDLibKit
import Testing
@testable import TelegramLink
import TelegramLinkTestSupport

@Test func messageIDsOrderByRawValue() {
    #expect(MessageID(1) < MessageID(2))
}

@Test func idsDescribeThemselvesAsTheirRawValue() {
    #expect(ChatID(-1_001_234_567_890).description == "-1001234567890")
    #expect(MessageID(42).description == "42")
    #expect("\(ChatID(5)):\(MessageID(7))" == "5:7")
}

@Test func configDefaultsToTheCurrentLanguage() throws {
    let config = TelegramConfig(
        apiID: 42,
        apiHash: "hash",
        databaseDirectory: URL(filePath: "/tmp/db", directoryHint: .isDirectory),
        filesDirectory: URL(filePath: "/tmp/files", directoryHint: .isDirectory),
        deviceModel: "Mac",
        systemVersion: "15.0",
        applicationVersion: "1 (1)"
    )

    let currentLanguage = try #require(Locale.current.language.languageCode?.identifier)
    #expect(config.systemLanguageCode == currentLanguage)
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

@Test func photoWithNoSizesKeepsItsCaptionButHasNoAttachment() {
    let content = MessageContent.messagePhoto(MessagePhoto(
        caption: formatted("a cat"),
        hasSpoiler: false,
        isSecret: false,
        photo: Photo(hasStickers: false, minithumbnail: nil, sizes: []),
        showCaptionAboveMedia: false,
        video: nil
    ))

    let body = Mapping.body(of: content)

    #expect(body.text == "a cat")
    #expect(body.attachment == nil)
}

@Test func eachKindOfContentTheAppDoesNotShowHasItsOwnPlaceholder() {
    let sticker = Sticker(
        emoji: "😀",
        format: .stickerFormatWebp,
        fullType: .stickerFullTypeRegular(StickerFullTypeRegular(premiumAnimation: nil)),
        height: 512,
        id: 1,
        setId: 0,
        sticker: file(id: 1),
        thumbnail: nil,
        width: 512
    )
    let audio = Audio(
        albumCoverMinithumbnail: nil,
        albumCoverThumbnail: nil,
        audio: file(id: 2),
        duration: 180,
        externalAlbumCovers: [],
        fileName: "song.mp3",
        mimeType: "audio/mpeg",
        performer: "",
        title: ""
    )
    let animation = Animation(
        animation: file(id: 3),
        duration: 2,
        fileName: "cat.mp4",
        hasStickers: false,
        height: 240,
        mimeType: "video/mp4",
        minithumbnail: nil,
        thumbnail: nil,
        width: 320
    )
    let location = Location(horizontalAccuracy: 0, latitude: 30.27, longitude: -97.74)
    let contact = Contact(firstName: "Sam", lastName: "", phoneNumber: "+15550000000", userId: 0, vcard: "")
    let poll = Poll(
        allowsMultipleAnswers: false,
        allowsRevoting: false,
        canGetVoters: false,
        canSeeResults: false,
        closeDate: 0,
        countryCodes: [],
        id: 1,
        isAnonymous: true,
        isClosed: false,
        membersOnly: false,
        openPeriod: 0,
        optionOrder: [],
        options: [],
        question: formatted("Lunch?"),
        recentVoterIds: [],
        totalVoterCount: 0,
        type: .pollTypeRegular,
        voteRestrictionReason: nil
    )
    let placeholders: [(content: MessageContent, text: String)] = [
        (.messageSticker(MessageSticker(isPremium: false, sticker: sticker)), "[sticker]"),
        (.messageExpiredVoiceNote, "[voice message]"),
        (.messageExpiredVideoNote, "[video message]"),
        (.messageAudio(MessageAudio(audio: audio, caption: formatted("listen"))), "[audio]"),
        (.messageExpiredVideo, "[video]"),
        (.messageExpiredPhoto, "[photo]"),
        (
            .messageAnimation(MessageAnimation(
                animation: animation,
                caption: formatted("look"),
                hasSpoiler: false,
                isSecret: false,
                showCaptionAboveMedia: false
            )),
            "[GIF]"
        ),
        (.messageLocation(MessageLocation(location: location)), "[location]"),
        (.messageContact(MessageContact(contact: contact)), "[contact]"),
        (
            .messagePoll(MessagePoll(canAddOption: false, description: formatted(""), media: nil, poll: poll)),
            "[poll]"
        ),
    ]

    for (content, text) in placeholders {
        let body = Mapping.body(of: content)
        #expect(body.text == text)
        #expect(body.attachment == nil)
    }
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

    let code = AuthorizationStateWaitCode(codeInfo: AuthenticationCodeInfo(
        nextType: nil,
        phoneNumber: "+15551234567",
        timeout: 0,
        type: .authenticationCodeTypeTelegramMessage(AuthenticationCodeTypeTelegramMessage(length: 5))
    ))
    #expect(Mapping.authState(.authorizationStateWaitCode(code)) == .needsCode)
}

@Test func authStatesTheAppDoesNotHandleAreUnsupportedByName() {
    let premium = AuthorizationStateWaitPremiumPurchase(
        premiumDayCount: 30,
        storeProductId: "premium",
        supportEmailAddress: "",
        supportEmailSubject: ""
    )
    let emailCode = AuthorizationStateWaitEmailCode(
        allowAppleId: false,
        allowGoogleId: false,
        codeInfo: EmailAddressAuthenticationCodeInfo(emailAddressPattern: "a***@example.com", length: 6),
        emailAddressResetState: nil
    )
    let otherDevice = AuthorizationStateWaitOtherDeviceConfirmation(link: "tg://login?token=abc")
    let registration = AuthorizationStateWaitRegistration(
        termsOfService: TermsOfService(minUserAge: 0, showPopup: false, text: formatted("Terms"))
    )

    #expect(Mapping.authState(.authorizationStateWaitPremiumPurchase(premium))
        == .unsupported("authorizationStateWaitPremiumPurchase"))
    #expect(Mapping.authState(.authorizationStateWaitEmailCode(emailCode))
        == .unsupported("authorizationStateWaitEmailCode"))
    #expect(Mapping.authState(.authorizationStateWaitOtherDeviceConfirmation(otherDevice))
        == .unsupported("authorizationStateWaitOtherDeviceConfirmation"))
    #expect(Mapping.authState(.authorizationStateWaitRegistration(registration))
        == .unsupported("authorizationStateWaitRegistration"))
}

@Test func authStateLogNamesLeaveOutTheirValues() {
    #expect(AuthState.starting.logName == "starting")
    #expect(AuthState.needsPhoneNumber.logName == "needsPhoneNumber")
    #expect(AuthState.needsCode.logName == "needsCode")
    #expect(AuthState.needsPassword(hint: "first dog").logName == "needsPassword")
    #expect(AuthState.ready.logName == "ready")
    #expect(AuthState.loggingOut.logName == "loggingOut")
    #expect(AuthState.closed.logName == "closed")
    #expect(AuthState.unsupported("setTdlibParameters failed: Can't lock file").logName == "unsupported")
}

// MARK: - Setup failures and logging

@Test func setupFailureReasonIsAFixedNameForTDLibsMessage() {
    #expect(TelegramLink.setupFailureReason(nil) == "notTDLib")
    #expect(TelegramLink.setupFailureReason("Valid api_id must be provided. Can be obtained at https://my.telegram.org")
        == "apiCredentials")
    #expect(TelegramLink.setupFailureReason("Valid api_hash must be provided") == "apiCredentials")
    #expect(TelegramLink.setupFailureReason("Can't lock file \"/Users/adam/db/td.binlog\", because it is already in use")
        == "databaseLocked")
    #expect(TelegramLink.setupFailureReason("Database is LOCKED by another process") == "databaseLocked")
    #expect(TelegramLink.setupFailureReason("Wrong database encryption key") == "other")
}

@Test func tdlibLogCodesAddTDLibsCodeButNeverItsMessage() {
    let tdlibError = TDLibKit.Error(code: 400, message: "Can't open /Users/adam/db/td.binlog")
    #expect(tdlibError.tdlibLogCodes(["reason": "databaseLocked"]) == [
        "reason": "databaseLocked",
        "errorDomain": "TDLibKit.Error",
        "errorCode": "1",
        "tdlibCode": "400",
    ])

    let linkError = TelegramLinkError.tdlib(code: 401, message: "Can't open /Users/adam/db/td.binlog")
    let linkCodes = linkError.tdlibLogCodes(["reason": "other"])
    #expect(linkCodes["tdlibCode"] == "401")
    #expect(linkCodes["reason"] == "other")
    #expect(!linkCodes.values.contains { $0.contains("td.binlog") })
}

@Test func tdlibLogCodesHaveNoTDLibCodeForOtherErrors() {
    #expect(URLError(.timedOut).tdlibLogCodes(["reason": "notTDLib"]) == [
        "reason": "notTDLib",
        "errorDomain": NSURLErrorDomain,
        "errorCode": "-1001",
    ])
    #expect(TelegramLinkError.notStarted.tdlibLogCodes()["tdlibCode"] == nil)
}

// MARK: - Files

@Test func fileRefHasALocalPathOnlyOnceTheDownloadFinished() {
    #expect(Mapping.fileRef(file(id: 4, downloadedPath: "/tmp/photo.jpg")) == FileRef(id: 4, localPath: "/tmp/photo.jpg"))
    #expect(Mapping.fileRef(file(id: 4)) == FileRef(id: 4, localPath: nil))
    // TDLib can report a finished download with no path, such as after the file was deleted.
    #expect(Mapping.fileRef(file(id: 4, downloadedPath: "")) == FileRef(id: 4, localPath: nil))
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

@Test func privateChatWithSomeoneElseIsNotThisBotsChat() {
    let bot = user(id: 6, type: .userTypeBot(botType()), username: "other_bot")
    let chat = chat(id: 5, title: "Winston", type: .chatTypePrivate(ChatTypePrivate(userId: 5)))

    #expect(Mapping.botChat(chat: chat, user: bot) == nil)
}

@Test func groupChatIsNotABotChat() {
    let bot = user(id: 5, type: .userTypeBot(botType()), username: "winston_bot")
    let chat = chat(id: 7, title: "Family", type: .chatTypeBasicGroup(ChatTypeBasicGroup(basicGroupId: 5)))

    #expect(Mapping.botChat(chat: chat, user: bot) == nil)
}
