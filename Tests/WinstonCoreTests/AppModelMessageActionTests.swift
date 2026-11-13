import Foundation
import Testing
import TelegramLink
import TelegramLinkTestSupport
import VoiceLoop
import VoiceLoopTestSupport
import WinstonCore

/// The 👍 button on the bot's latest message, and marking messages read.
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
