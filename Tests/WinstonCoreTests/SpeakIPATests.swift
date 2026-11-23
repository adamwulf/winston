import Foundation
import TelegramLink
import Testing
import VoiceLoop
import VoiceLoopTestSupport
import WinstonCore

/// Speak IPA, the message list's menu item: a message said with the on-device model's IPA, a chunk
/// at a time, what stops it, and what Adam is told.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SpeakIPATests {
    /// A harness with the Heart voice chosen and its model ready.
    private func harnessWithKokoro(speakIPATimeout: Duration = SpeakIPA.defaultTimeout) async -> Harness {
        let harness = Harness(speakIPATimeout: speakIPATimeout)
        harness.model.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { harness.model.voiceLoop.kokoroModelState == .ready })
        return harness
    }

    private func message(_ text: String, id: Int64 = 11, chat: Int64 = 1) -> ChatMessage {
        ChatMessage(id: MessageID(id), chatID: ChatID(chat), isOutgoing: false, date: .now, text: text)
    }

    /// Two chunks, a sentence each: the first is long enough to be the first chunk, and the second
    /// too long to join it. 9 words, then 15.
    private let firstSentence = "This first sentence is long enough to stand alone."
    private let secondSentence = "The second one follows it, with the words it has and the words it adds."
    private var twoChunks: String { firstSentence + " " + secondSentence }

    @Test func aMessageIsSaidAChunkAtATimeWithTheModelsIPA() async throws {
        let harness = await harnessWithKokoro()
        let speakIPA = harness.model.speakIPA
        let message = message(twoChunks)
        let phases = ValueLog { speakIPA.phase(for: message) }

        speakIPA.toggle(message)

        #expect(speakIPA.phase(for: message) == .preparing)
        #expect(await eventually { speakIPA.phase(for: message) == nil })
        #expect(phases.values == [nil, .preparing, .speaking, nil])
        #expect(harness.transcriber.chunks == [firstSentence, secondSentence])
        #expect(Set(harness.transcriber.requestNumbers).count == 1)
        // Every word went to Kokoro as a placeholder with its phonemes.
        let requests = harness.bed.kokoro.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { !$0.pronunciations.isEmpty && $0.pronunciations.values.allSatisfy { $0 == "ə" } })
        #expect(requests.first?.pronunciations.count == 9)
        #expect(!requests.contains { $0.text.contains("sentence") })
        // All of it was said from the model's IPA: nothing to tell.
        #expect(speakIPA.note(for: message) == nil)
    }

    @Test func tappingItAgainStopsIt() async throws {
        let harness = await harnessWithKokoro()
        let speakIPA = harness.model.speakIPA
        let message = message(twoChunks)
        harness.transcriber.holdsAnswers = true

        speakIPA.toggle(message)
        #expect(await eventually { harness.transcriber.heldAnswers == 1 })
        speakIPA.toggle(message)

        #expect(speakIPA.phase(for: message) == nil)
        #expect(await eventually { harness.transcriber.cancelledRequests == [0] })
        harness.transcriber.releaseAnswers()
        try await settle()
        #expect(harness.transcriber.chunks.count == 1)
        #expect(harness.bed.kokoro.requests.isEmpty)
        #expect(speakIPA.note(for: message) == nil)
    }

    @Test func theStopButtonStopsItWhileItPlays() async throws {
        let harness = await harnessWithKokoro()
        let speakIPA = harness.model.speakIPA
        let message = message(twoChunks)
        harness.bed.kokoro.holdsSynthesis = true

        speakIPA.toggle(message)
        #expect(await eventually { harness.bed.kokoro.heldSyntheses == 1 })
        speakIPA.stop()

        #expect(speakIPA.phase(for: message) == nil)
        harness.bed.kokoro.holdsSynthesis = false
        harness.bed.kokoro.releaseSyntheses()
        try await settle()
        #expect(harness.bed.audio.playedFrames == 0)
    }

    @Test func anotherMessageReplacesTheOneBeingSaid() async throws {
        let harness = await harnessWithKokoro()
        let speakIPA = harness.model.speakIPA
        let first = message(twoChunks, id: 11)
        let second = message("Second message.", id: 12)
        harness.transcriber.holdsAnswers = true
        speakIPA.toggle(first)
        #expect(await eventually { harness.transcriber.heldAnswers == 1 })

        harness.transcriber.holdsAnswers = false
        speakIPA.toggle(second)

        #expect(speakIPA.phase(for: first) == nil)
        #expect(speakIPA.phase(for: second) == .preparing)
        #expect(await eventually { harness.transcriber.cancelledRequests == [0] })
        harness.transcriber.releaseAnswers()
        #expect(await eventually { speakIPA.phase(for: second) == nil })
        #expect(harness.transcriber.chunks == [firstSentence, "Second message."])
        // The first message's late answer was dropped: only the second was said.
        #expect(harness.bed.kokoro.requests.count == 1)
    }

    @Test func showingAnotherChatStopsIt() async throws {
        let harness = await harnessWithKokoro()
        let speakIPA = harness.model.speakIPA
        let message = message(twoChunks, chat: 1)
        harness.model.selectedChatID = ChatID(1)
        harness.transcriber.holdsAnswers = true
        speakIPA.toggle(message)
        #expect(await eventually { harness.transcriber.heldAnswers == 1 })

        harness.model.selectedChatID = ChatID(1)
        #expect(speakIPA.phase(for: message) == .preparing)
        harness.model.selectedChatID = ChatID(2)

        #expect(speakIPA.phase(for: message) == nil)
        #expect(await eventually { harness.transcriber.cancelledRequests == [0] })
        harness.transcriber.releaseAnswers()
    }

    @Test func speakingAnotherMessageCutsItOffWithoutANote() async throws {
        let harness = await harnessWithKokoro()
        let speakIPA = harness.model.speakIPA
        let message = message(twoChunks)
        harness.transcriber.holdsAnswers = true
        speakIPA.toggle(message)
        #expect(await eventually { harness.transcriber.heldAnswers == 1 })

        harness.model.readAloud(self.message("Something else.", id: 12))

        #expect(speakIPA.phase(for: message) == nil)
        #expect(await eventually { harness.transcriber.cancelledRequests == [0] })
        harness.transcriber.releaseAnswers()
        try await settle()
        #expect(speakIPA.note(for: message) == nil)
    }

    @Test func aChunkTheModelFailsOnIsSaidAsWrittenAndTheNoteSaysSo() async throws {
        let harness = await harnessWithKokoro()
        let speakIPA = harness.model.speakIPA
        let message = message(twoChunks)
        harness.transcriber.answers = [.failure(.declined)]

        speakIPA.toggle(message)

        #expect(await eventually { speakIPA.phase(for: message) == nil })
        let requests = harness.bed.kokoro.requests
        #expect(requests.first == FakeKokoro.Request(text: firstSentence, voice: "af_heart", speed: 1))
        #expect(requests.count == 2)
        // 15 words: "the" and "words" twice and "it" three times, each with one placeholder.
        #expect(requests.last?.pronunciations.count == 11)
        // The model was still asked about the second chunk.
        #expect(harness.transcriber.chunks.count == 2)
        #expect(speakIPA.note(for: message)
            == "15 of 24 words were said from Apple Intelligence's IPA; the rest as Kokoro reads them. The model declined part of the message.")
    }

    @Test func aChunkWhoseIPAKokoroCantSayIsSaidAsWritten() async throws {
        let harness = await harnessWithKokoro()
        let speakIPA = harness.model.speakIPA
        let message = message("Bach and Bloch.")
        // x isn't one of Kokoro's symbols.
        harness.transcriber.answers = [.success([
            TranscribedWord(word: "Bach", ipa: "bɑx"),
            TranscribedWord(word: "and", ipa: "ænd"),
            TranscribedWord(word: "Bloch", ipa: "blɑx"),
        ])]

        speakIPA.toggle(message)

        #expect(await eventually { speakIPA.phase(for: message) == nil })
        #expect(harness.bed.kokoro.requests.map(\.text) == ["Bach and Bloch."])
        #expect(speakIPA.note(for: message) == "0 of 3 words were said from Apple Intelligence's IPA; the rest as Kokoro reads them.")
        speakIPA.dismissNote()
        #expect(speakIPA.note(for: message) == nil)
    }

    @Test func aChunkNotAnsweredInTimeIsGivenUpOnAndTheRestIsSaidAsWritten() async throws {
        let harness = await harnessWithKokoro(speakIPATimeout: .milliseconds(200))
        let speakIPA = harness.model.speakIPA
        let message = message(twoChunks)
        harness.transcriber.holdsAnswers = true

        speakIPA.toggle(message)

        #expect(await eventually { speakIPA.phase(for: message) == nil })
        #expect(harness.transcriber.cancelledRequests == [0])
        // Not asked again: a model that stalled once would likely stall again.
        #expect(harness.transcriber.chunks.count == 1)
        #expect(harness.bed.kokoro.requests.map(\.text) == [firstSentence, secondSentence])
        #expect(speakIPA.note(for: message)?.hasSuffix("Apple Intelligence didn't answer in time.") == true)
        harness.transcriber.releaseAnswers()
    }

    @Test func itSaysWhyItCantStart() async throws {
        let harness = Harness()
        let speakIPA = harness.model.speakIPA
        let message = message("Hello there.")

        // A system voice says no IPA.
        speakIPA.toggle(message)
        #expect(speakIPA.note(for: message) == "Speak IPA needs a Kokoro voice: only Kokoro can say IPA. Choose one in Settings.")

        harness.model.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { harness.model.voiceLoop.kokoroModelState == .ready })
        harness.transcriber.availability = .unavailable(.appleIntelligenceNotEnabled)
        speakIPA.toggle(message)
        #expect(speakIPA.note(for: message)?.hasPrefix("Speak IPA needs Apple Intelligence, which is turned off.") == true)

        harness.transcriber.availability = .available
        let codeOnly = self.message("```\nlet x = 1\n```", id: 12)
        speakIPA.toggle(codeOnly)
        #expect(speakIPA.note(for: codeOnly) == "This message has nothing Speak IPA can say.")
        // A note is for its message only.
        #expect(speakIPA.note(for: message) == nil)

        await harness.model.setVoiceMode(true)
        speakIPA.toggle(message)
        #expect(speakIPA.note(for: message) == "Speak IPA plays only while voice mode is off.")
        await harness.model.setVoiceMode(false)

        #expect(harness.transcriber.chunks.isEmpty)
        #expect(speakIPA.phase(for: message) == nil)
    }

    @Test func turningOnVoiceModeStopsIt() async throws {
        let harness = await harnessWithKokoro()
        let speakIPA = harness.model.speakIPA
        let message = message(twoChunks)
        harness.transcriber.holdsAnswers = true
        speakIPA.toggle(message)
        #expect(await eventually { harness.transcriber.heldAnswers == 1 })

        await harness.model.setVoiceMode(true)

        #expect(speakIPA.phase(for: message) == nil)
        #expect(await eventually { harness.transcriber.cancelledRequests == [0] })
        harness.transcriber.releaseAnswers()
        await harness.model.setVoiceMode(false)
    }

    @Test func sayingAMessageAgainUsesTheIPAKeptForIt() async throws {
        let harness = await harnessWithKokoro()
        let speakIPA = harness.model.speakIPA
        let message = message(twoChunks)
        speakIPA.toggle(message)
        #expect(await eventually { speakIPA.phase(for: message) == nil })
        let firstRequests = harness.bed.kokoro.requests

        speakIPA.toggle(message)
        #expect(await eventually { speakIPA.phase(for: message) == nil })

        // The model wasn't asked again, and the same placeholders were said.
        #expect(harness.transcriber.chunks.count == 2)
        #expect(Array(harness.bed.kokoro.requests.dropFirst(2)) == firstRequests)
    }

    @Test func ipaSaidAsWrittenIsNotKept() async throws {
        let harness = await harnessWithKokoro()
        let speakIPA = harness.model.speakIPA
        let message = message("Bach.")
        harness.transcriber.answers = [.success([TranscribedWord(word: "Bach", ipa: "bɑx")])]
        speakIPA.toggle(message)
        #expect(await eventually { speakIPA.phase(for: message) == nil })

        speakIPA.toggle(message)
        #expect(await eventually { speakIPA.phase(for: message) == nil })

        // Asked again: the first answer couldn't be used, and the next may be better.
        #expect(harness.transcriber.chunks == ["Bach.", "Bach."])
    }
}
