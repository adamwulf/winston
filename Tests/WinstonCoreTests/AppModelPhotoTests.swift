import Foundation
import Testing
import TelegramLink
import TelegramLinkTestSupport
import VoiceLoop
import VoiceLoopTestSupport
import WinstonCore

/// An error from loading a picked photo, with a description of its own.
private struct PhotoLibraryUnavailable: LocalizedError {
    var errorDescription: String? { "The photo library isn't available." }
}

/// The photo TDLib was last asked to send, or nil if the last request wasn't one.
@MainActor
private func lastSentPhoto(of harness: Harness) -> (chatID: Int64?, path: String, caption: String?, width: Int, height: Int)? {
    guard case .sendPhoto(let chatID, let path, let caption, let width, let height)? = harness.fake.requests.last else {
        return nil
    }
    return (chatID, path, caption, width, height)
}

/// Sending a picked photo: re-encoded as a JPEG in the temporary folder, then handed to TDLib.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SendPhotoTests {
    @Test func aPhotoIsSentAsAJPEGOfItsSizeWithNoCaptionWhenTheCaptionIsEmpty() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let png = try imageData(width: 40, height: 30)
        harness.fake.hold(.sendMessage)

        let send = Task { await model.sendPhoto(caption: "") { png } }

        #expect(await eventually { lastSentPhoto(of: harness) != nil })
        #expect(model.isSendingPhoto)
        harness.fake.release(.sendMessage)
        #expect(await send.value)
        #expect(!model.isSendingPhoto)

        let sent = try #require(lastSentPhoto(of: harness))
        let jpeg = URL(filePath: sent.path)
        defer { try? FileManager.default.removeItem(at: jpeg) }
        #expect(sent.chatID == 1)
        #expect(sent.caption == nil)
        #expect(sent.width == 40)
        #expect(sent.height == 30)
        #expect(jpeg.deletingLastPathComponent().pathComponents == URL.temporaryDirectory.pathComponents)
        #expect(jpeg.pathExtension == "jpg")
        #expect(try imageFileInfo(at: jpeg) == ImageFileInfo(type: "public.jpeg", width: 40, height: 30))
        // The pending message shows the photo from the file being uploaded.
        #expect(await eventually {
            model.currentMessages.last?.attachment == .photo(FileRef(id: 1, localPath: sent.path), width: 40, height: 30)
        })
        #expect(model.currentMessages.last?.sendState == .pending)
        #expect(model.errorMessage == nil)
    }

    @Test func aCaptionIsSentAsGiven() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let png = try imageData(width: 40, height: 30)

        #expect(await model.sendPhoto(caption: "The build light is red.") { png })

        let sent = try #require(lastSentPhoto(of: harness))
        try? FileManager.default.removeItem(at: URL(filePath: sent.path))
        #expect(sent.chatID == 1)
        #expect(sent.caption == "The build light is red.")
    }

    @Test func aPhotoThatCannotBeLoadedIsNotSent() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let requests = harness.fake.requests.count

        #expect(await model.sendPhoto(caption: "") { nil } == false)

        #expect(model.errorMessage == "Winston couldn't read that photo.")
        #expect(!model.isSendingPhoto)
        #expect(harness.fake.requests.count == requests)
    }

    @Test func dataThatIsNotAnImageIsNotSent() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let requests = harness.fake.requests.count

        #expect(await model.sendPhoto(caption: "") { Data("not an image".utf8) } == false)

        #expect(model.errorMessage == "Winston couldn't read that photo.")
        #expect(!model.isSendingPhoto)
        #expect(harness.fake.requests.count == requests)
    }

    @Test func anErrorLoadingThePhotoIsShown() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let requests = harness.fake.requests.count

        #expect(await model.sendPhoto(caption: "") { throw PhotoLibraryUnavailable() } == false)

        #expect(model.errorMessage == "The photo library isn't available.")
        #expect(!model.isSendingPhoto)
        #expect(harness.fake.requests.count == requests)
    }

    @Test func aPhotoTDLibRefusesShowsTheError() async throws {
        let harness = Harness.withTwoBots()
        harness.fake.fail(.sendMessage, code: 400, message: "PHOTO_INVALID_DIMENSIONS")
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let png = try imageData(width: 40, height: 30)

        #expect(await model.sendPhoto(caption: "") { png } == false)

        let sent = try #require(lastSentPhoto(of: harness))
        try? FileManager.default.removeItem(at: URL(filePath: sent.path))
        #expect(model.errorMessage == "PHOTO_INVALID_DIMENSIONS")
        #expect(!model.isSendingPhoto)
    }

    @Test func withNoChatChosenThePhotoIsNotEvenLoaded() async throws {
        let harness = Harness()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        let requests = harness.fake.requests.count
        var loaded = false

        let sent = await model.sendPhoto(caption: "") {
            loaded = true
            return try imageData(width: 40, height: 30)
        }

        #expect(!sent)
        #expect(!loaded)
        #expect(!model.isSendingPhoto)
        #expect(model.errorMessage == nil)
        #expect(harness.fake.requests.count == requests)
    }
}
