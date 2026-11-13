import Foundation
import Testing
import TelegramLink
import VoiceLoop
import WinstonCore

/// An error that isn't one of Winston's, with a description of its own.
private struct DiskFull: LocalizedError {
    var errorDescription: String? { "The disk is full." }
}

/// The sentence the app shows for an error.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct UserMessageTests {
    @Test func telegramErrorsShowTDLibsMessageOrSayTelegramHasNotStarted() {
        #expect(userMessage(for: TelegramLinkError.tdlib(code: 400, message: "PHONE_CODE_INVALID")) == "PHONE_CODE_INVALID")
        #expect(userMessage(for: TelegramLinkError.notStarted) == "Telegram hasn't started yet.")
    }

    @Test func voiceErrorsSayWhatToTurnOn() {
        #expect(userMessage(for: VoiceLoopError.microphonePermissionDenied)
            == "Winston can't use the microphone. Turn on microphone access for Winston in Privacy & Security settings.")
        #expect(userMessage(for: VoiceLoopError.speechPermissionDenied)
            == "Winston can't use speech recognition. Turn on speech recognition for Winston in Privacy & Security settings.")
        #expect(userMessage(for: VoiceLoopError.speechModelUnavailable)
            == "The on-device speech model for your language isn't available.")
    }

    @Test func photoErrorsSayWhatWentWrongWithThePhoto() {
        #expect(userMessage(for: PhotoFiles.Failure.unreadableImage) == "Winston couldn't read that photo.")
        #expect(userMessage(for: PhotoFiles.Failure.encodingFailed) == "Winston couldn't convert that photo to JPEG.")
    }

    @Test func anyOtherErrorShowsItsOwnDescription() {
        #expect(userMessage(for: DiskFull()) == "The disk is full.")
        let timedOut = URLError(.timedOut)
        #expect(userMessage(for: timedOut) == timedOut.localizedDescription)
    }
}
