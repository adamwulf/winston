import Foundation
import Testing
import TelegramLink
import TelegramLinkTestSupport
import VoiceLoop
import VoiceLoopTestSupport
import WinstonCore

/// The 👍 Adam toggles on a message, and marking messages read.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ReactionAndReadTests {
    @Test func thumbsUpIsAddedToTheBotsLatestMessageThenRemoved() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let latest = try #require(model.latestIncomingMessage)
        #expect(latest.id == MessageID(11))

        await model.toggleThumbsUp(on: latest)

        #expect(harness.fake.requests.suffix(2) == [
            .getMessage(chatID: 1, messageID: 11),
            .addReaction(chatID: 1, messageID: 11, emoji: "👍"),
        ])
        #expect(await eventually {
            model.latestIncomingMessage?.reactions == [Reaction(emoji: "👍", count: 1, isChosen: true)]
        })

        await model.toggleThumbsUp(on: try #require(model.latestIncomingMessage))

        #expect(harness.fake.requests.suffix(2) == [
            .getMessage(chatID: 1, messageID: 11),
            .removeReaction(chatID: 1, messageID: 11, emoji: "👍"),
        ])
        #expect(await eventually { model.latestIncomingMessage?.reactions == [] })
        #expect(model.errorMessage == nil)
    }

    @Test func aThumbsUpTDLibRefusesShowsTheError() async throws {
        let harness = Harness.withTwoBots()
        harness.fake.fail(.addMessageReaction, code: 400, message: "REACTION_INVALID")
        #expect(await harness.startAndLoadChats())
        let model = harness.model

        await model.toggleThumbsUp(on: try #require(model.latestIncomingMessage))

        #expect(harness.fake.requests.last == .addReaction(chatID: 1, messageID: 11, emoji: "👍"))
        #expect(model.errorMessage == "REACTION_INVALID")
        #expect(model.latestIncomingMessage?.reactions == [])
        #expect(model.addedThumbsUp == nil)

        // The refused 👍 is forgotten: one Adam adds in another app afterwards isn't scrolled to.
        try harness.fake.adamReactsInAnotherApp("👍", to: 11, in: 1)
        #expect(await eventually { model.latestIncomingMessage?.hasMyThumbsUp == true })
        #expect(model.addedThumbsUp == nil)
    }

    @Test func aThumbsUpAdamAddsIsScrolledToOnceItShows() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let latest = try #require(model.latestIncomingMessage)
        harness.fake.hold(.addMessageReaction)

        let toggle = Task { await model.toggleThumbsUp(on: latest) }

        #expect(await eventually { harness.fake.isWaiting(on: .addMessageReaction) })
        #expect(model.addedThumbsUp == nil)
        harness.fake.release(.addMessageReaction)
        await toggle.value
        #expect(await eventually { model.addedThumbsUp?.messageID == MessageID(11) })
        // Set with the 👍 itself, so the message list has the reaction to scroll to.
        #expect(model.latestIncomingMessage?.hasMyThumbsUp == true)
    }

    @Test func eachThumbsUpAdamAddsIsScrolledToButRemovingOneIsNot() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model

        await model.toggleThumbsUp(on: try #require(model.latestIncomingMessage))
        #expect(await eventually { model.addedThumbsUp != nil })
        let first = try #require(model.addedThumbsUp)

        await model.toggleThumbsUp(on: try #require(model.latestIncomingMessage))
        #expect(await eventually { model.latestIncomingMessage?.reactions == [] })
        #expect(model.addedThumbsUp == first)

        // Adding it back is a change the message list sees, though the message is the same.
        await model.toggleThumbsUp(on: try #require(model.latestIncomingMessage))
        #expect(await eventually { model.addedThumbsUp != first })
        #expect(model.addedThumbsUp?.messageID == MessageID(11))
    }

    @Test func aThumbsUpFromTheBotOrFromAnotherAppIsNotScrolledTo() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model

        try harness.fake.botReacts("👍", to: 11, in: 1)
        try harness.fake.adamReactsInAnotherApp("👍", to: 11, in: 1)

        #expect(await eventually {
            model.latestIncomingMessage?.reactions == [Reaction(emoji: "👍", count: 2, isChosen: true)]
        })
        #expect(model.addedThumbsUp == nil)
    }

    @Test func aThumbsUpThatShowsAfterAdamChangesChatsIsNotScrolledTo() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let latest = try #require(model.latestIncomingMessage)
        harness.fake.hold(.addMessageReaction)

        let toggle = Task { await model.toggleThumbsUp(on: latest) }

        #expect(await eventually { harness.fake.isWaiting(on: .addMessageReaction) })
        model.selectedChatID = ChatID(2)
        harness.fake.release(.addMessageReaction)
        await toggle.value
        #expect(await eventually { model.messages[ChatID(1)]?.last?.hasMyThumbsUp == true })
        #expect(model.addedThumbsUp == nil)
    }

    @Test func markingAnIncomingMessageReadViewsItInTDLib() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model

        model.markRead(try #require(model.latestIncomingMessage))

        #expect(await eventually {
            harness.fake.requests.last == .viewMessages(chatID: 1, messageIDs: [11], forceRead: true)
        })
    }

    @Test func markingAnOutgoingMessageReadSendsNothing() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let requests = harness.fake.requests.count

        model.markRead(try #require(model.currentMessages.first { $0.isOutgoing }))

        try await settle()
        #expect(harness.fake.requests.count == requests)
    }

    @Test func aFailureToMarkReadIsNotShown() async throws {
        let harness = Harness.withTwoBots()
        harness.fake.fail(.viewMessages, code: 400, message: "MESSAGE_ID_INVALID")
        #expect(await harness.startAndLoadChats())
        let model = harness.model

        model.markRead(try #require(model.latestIncomingMessage))

        #expect(await eventually {
            harness.fake.requests.last == .viewMessages(chatID: 1, messageIDs: [11], forceRead: true)
        })
        try await settle()
        #expect(model.errorMessage == nil)
    }
}

/// Photos and documents the bots send, downloaded to show or open.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FileTests {
    @Test func aFileAlreadyDownloadedIsUsedWhereItIs() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let downloaded = FileRef(id: 7, localPath: "/tmp/winston-tests/files/photo.jpg")
        let requests = harness.fake.requests.count

        #expect(model.localURL(for: downloaded) == URL(filePath: "/tmp/winston-tests/files/photo.jpg"))
        #expect(try await model.download(downloaded) == URL(filePath: "/tmp/winston-tests/files/photo.jpg"))
        #expect(model.localURL(for: FileRef(id: 8, localPath: nil)) == nil)
        #expect(harness.fake.requests.count == requests)
    }

    @Test func aDownloadAsksTDLibOnceAndRemembersWhereTheFileIs() async throws {
        let harness = Harness.withTwoBots()
        harness.fake.setFile(file(id: 7, downloadedPath: "/tmp/winston-tests/files/photo.jpg"))
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let photo = FileRef(id: 7, localPath: nil)
        let local = URL(filePath: "/tmp/winston-tests/files/photo.jpg")
        #expect(!model.isDownloading(photo))
        harness.fake.hold(.downloadFile)

        let download = Task { try await model.download(photo) }

        #expect(await eventually { harness.fake.requests.last == .downloadFile(fileID: 7) })
        #expect(model.isDownloading(photo))
        #expect(!model.isDownloading(FileRef(id: 8, localPath: nil)))
        harness.fake.release(.downloadFile)
        #expect(try await download.value == local)
        #expect(!model.isDownloading(photo))
        #expect(model.localURL(for: photo) == local)

        #expect(try await model.download(photo) == local)
        #expect(harness.fake.requests.filter { $0 == .downloadFile(fileID: 7) }.count == 1)
    }

    @Test func aFailedDownloadThrowsAndIsNoLongerDownloading() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        // TDLib has no file 7.
        let photo = FileRef(id: 7, localPath: nil)

        await #expect(throws: TelegramLinkError.tdlib(code: 400, message: "Invalid file identifier")) {
            try await model.download(photo)
        }

        #expect(harness.fake.requests.last == .downloadFile(fileID: 7))
        #expect(!model.isDownloading(photo))
        #expect(model.localURL(for: photo) == nil)
    }
}
