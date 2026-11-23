import Foundation
import TelegramLink
import Testing
import VoiceLoop
import VoiceLoopTestSupport
import WinstonCore

/// A recognizer failure, which ends the voice loop on its own.
private struct RecognizerFailure: Error {}

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
        // All of it was said from the model's IPA, with nothing changed.
        #expect(speakIPA.note(for: message) == "24 of 24 words were said from Apple Intelligence's IPA.")
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

    @Test func anotherMessageReplacesTheOneBeingSaidAndTheFirstsLateAnswerIsDropped() async throws {
        let harness = await harnessWithKokoro()
        let speakIPA = harness.model.speakIPA
        let first = message(twoChunks, id: 11)
        let second = message("Second message.", id: 12)
        // Told apart by their IPA. The first answer's words are the second message's, so only
        // the request it answers keeps it out.
        harness.transcriber.answers = [
            .success([TranscribedWord(word: "Second", ipa: "fˈɜɹst"), TranscribedWord(word: "message", ipa: "fˈɜɹst")]),
            .success([TranscribedWord(word: "Second", ipa: "sˈɛkənd"), TranscribedWord(word: "message", ipa: "mˈɛsəʤ")]),
        ]
        harness.transcriber.holdsAnswers = true
        speakIPA.toggle(first)
        #expect(await eventually { harness.transcriber.heldAnswers == 1 })

        speakIPA.toggle(second)
        #expect(speakIPA.phase(for: first) == nil)
        #expect(await eventually { harness.transcriber.heldAnswers == 2 })
        #expect(harness.transcriber.cancelledRequests == [0])

        // The first message's answer comes first, late: dropped.
        harness.transcriber.releaseAnswer(0)
        try await settle()
        #expect(speakIPA.phase(for: second) == .preparing)
        #expect(harness.bed.kokoro.requests.isEmpty)

        harness.transcriber.releaseAnswer(1)
        #expect(await eventually { speakIPA.phase(for: second) == nil })
        #expect(harness.transcriber.chunks == [firstSentence, "Second message."])
        #expect(harness.bed.kokoro.requests.map { Set($0.pronunciations.values) } == [["sˈɛkənd", "mˈɛsəʤ"]])
    }

    @Test func stopSpeakingIPAOnAMessageThatHasFinishedDoesNothing() async throws {
        let harness = await harnessWithKokoro()
        let speakIPA = harness.model.speakIPA
        let message = message("Short one.")
        speakIPA.toggle(message)
        #expect(await eventually { speakIPA.phase(for: message) == nil })

        // As from a menu opened while it played.
        speakIPA.stop(message)

        #expect(speakIPA.phase(for: message) == nil)
        try await settle()
        #expect(harness.transcriber.chunks.count == 1)
        #expect(harness.bed.kokoro.requests.count == 1)
    }

    @Test func aMessageSentWhileItIsSaidKeepsItsStatusUnderItsNewID() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        model.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { model.voiceLoop.kokoroModelState == .ready })
        #expect(await model.sendText("Run the tests."))
        #expect(await eventually { model.currentMessages.last?.text == "Run the tests." })
        let pending = try #require(model.currentMessages.last)
        #expect(pending.sendState == .pending)
        harness.transcriber.holdsAnswers = true
        model.speakIPA.toggle(pending)
        #expect(await eventually { harness.transcriber.heldAnswers == 1 })

        harness.fake.confirmSend(of: pending.id.rawValue, in: 1, as: 13)
        #expect(await eventually { model.currentMessages.last?.id == MessageID(13) })
        let sent = try #require(model.currentMessages.last)

        #expect(model.speakIPA.phase(for: sent) == .preparing)
        model.speakIPA.stop(sent)
        #expect(model.speakIPA.phase(for: sent) == nil)
        #expect(await eventually { harness.transcriber.cancelledRequests == [0] })
        harness.transcriber.releaseAnswers()
    }

    @Test func aCancelThatDidntComeFromSpeakIPAIsAChunkFailureAndTheMessageGoesOn() async throws {
        let harness = await harnessWithKokoro()
        let speakIPA = harness.model.speakIPA
        let message = message(twoChunks)
        harness.transcriber.answers = [.failure(CancellationError())]

        speakIPA.toggle(message)

        #expect(await eventually { speakIPA.phase(for: message) == nil })
        #expect(harness.transcriber.chunks.count == 2)
        #expect(harness.bed.kokoro.requests.first?.text == firstSentence)
        #expect(harness.bed.kokoro.requests.count == 2)
        #expect(speakIPA.note(for: message)?.hasSuffix("\nSaid as written: part 1 of 2 (the model failed on it).") == true)
    }

    @Test func ifKokoroFailsTheNoteSaysTheRestWasntSaidAndTheRefusedAnswerIsntKept() async throws {
        let harness = await harnessWithKokoro()
        let speakIPA = harness.model.speakIPA
        let message = message(twoChunks)
        harness.bed.kokoro.failingRequest = 0
        harness.bed.kokoro.holdsSynthesis = true
        harness.transcriber.holdsAnswers = true

        speakIPA.toggle(message)
        #expect(await eventually { harness.transcriber.heldAnswers == 1 })
        harness.transcriber.releaseAnswer(0)
        // The second chunk is being written as Kokoro fails on the first.
        #expect(await eventually { harness.transcriber.heldAnswers == 1 && harness.bed.kokoro.heldSyntheses == 1 })
        harness.bed.kokoro.holdsSynthesis = false
        harness.bed.kokoro.releaseSyntheses()
        #expect(await eventually { harness.bed.systemVoiceTexts.count == 1 })
        harness.transcriber.releaseAnswer(1)

        #expect(await eventually { speakIPA.phase(for: message) == nil })
        #expect(speakIPA.note(for: message)
            == "The Kokoro voice stopped partway: the system voice finished the part it was on, and the rest wasn't said.")
        // Said again: the second chunk's answer came after the speech refused it, so it wasn't
        // kept, and the model is asked again.
        harness.transcriber.holdsAnswers = false
        speakIPA.toggle(message)
        #expect(await eventually { speakIPA.phase(for: message) == nil })
        #expect(harness.transcriber.chunks == [firstSentence, secondSentence, secondSentence])
    }

    @Test func ifKokoroFailsOnTheLastChunkTheNoteSaysTheSystemVoiceSaidTheRest() async throws {
        let harness = await harnessWithKokoro()
        let speakIPA = harness.model.speakIPA
        let message = message("Short one.")
        harness.bed.kokoro.failingRequest = 0

        speakIPA.toggle(message)

        #expect(await eventually { speakIPA.phase(for: message) == nil })
        #expect(speakIPA.note(for: message) == "The Kokoro voice stopped partway: the system voice said the rest of the message.")
    }

    @Test func itDoesntStartWhileVoiceModeShowsResumeListening() async throws {
        let harness = await harnessWithKokoro()
        let model = harness.model
        await model.setVoiceMode(true)
        harness.bed.recognizer.fail(RecognizerFailure())
        #expect(await eventually { model.voiceLoop.state == .off })
        // Voice mode stays on in the app, which offers to resume it.
        #expect(model.isVoiceMode)
        let engines = harness.bed.audio.engines.count

        let message = message("Hello there.")
        model.speakIPA.toggle(message)

        #expect(model.speakIPA.note(for: message) == "Speak IPA plays only while voice mode is off.")
        #expect(harness.transcriber.chunks.isEmpty)
        #expect(harness.bed.audio.engines.count == engines)
        await model.setVoiceMode(false)
    }

    @Test func aMessageWhoseIPAIsKeptIsSaidAgainWithoutTheModel() async throws {
        let harness = await harnessWithKokoro()
        let speakIPA = harness.model.speakIPA
        let message = message(twoChunks)
        speakIPA.toggle(message)
        #expect(await eventually { speakIPA.phase(for: message) == nil })

        harness.transcriber.availability = .unavailable(.modelNotReady)
        let reads = harness.transcriber.availabilityReads
        speakIPA.toggle(message)

        // Not even asked whether the model can run.
        #expect(harness.transcriber.availabilityReads == reads)
        #expect(speakIPA.note(for: message) == nil)
        #expect(await eventually { speakIPA.phase(for: message) == nil })
        #expect(harness.bed.kokoro.requests.count == 4)
        #expect(speakIPA.note(for: message) == "24 of 24 words were said from Apple Intelligence's IPA.")
        // Another message needs the model, and says why it can't have it.
        let other = self.message("Something new.", id: 12)
        speakIPA.toggle(other)
        #expect(speakIPA.note(for: other)?.hasPrefix("Apple Intelligence isn't ready yet") == true)
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
        harness.transcriber.answers = [.failure(PronunciationSuggestionError.declined)]

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
            == "15 of 24 words were said from Apple Intelligence's IPA.\nSaid as written: part 1 of 2 (the model declined it).")
    }

    @Test func everyWordIsSaidFromTheModelsIPAAndTheNoteSaysWhatChanged() async throws {
        let harness = await harnessWithKokoro()
        let speakIPA = harness.model.speakIPA
        let message = message("Bach and Bloch, uh, again.")
        // x isn't one of Kokoro's symbols, nor ʔ; "uh" has no sound left, and "again" no IPA.
        harness.transcriber.answers = [.success([
            TranscribedWord(word: "Bach", ipa: "bɑx"),
            TranscribedWord(word: "and", ipa: "ænd"),
            TranscribedWord(word: "Bloch", ipa: "blɑxʔ"),
            TranscribedWord(word: "uh", ipa: "ʔ"),
        ])]

        speakIPA.toggle(message)

        #expect(await eventually { speakIPA.phase(for: message) == nil })
        #expect(harness.bed.kokoro.requests.map { Set($0.pronunciations.values) } == [["bɑk", "ænd", "blɑk"]])
        #expect(speakIPA.note(for: message) == """
            3 of 5 words were said from Apple Intelligence's IPA.
            Put as the closest sound Kokoro has: x → k ×2 (Bach, Bloch).
            Left out, with nothing close: ʔ ×2 (Bloch, uh).
            No IPA from the model, so said as Kokoro reads them: again.
            No sound left in the model's IPA, so said as Kokoro reads them: uh.
            """)
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
        #expect(speakIPA.note(for: message) == """
            0 of 24 words were said from Apple Intelligence's IPA.
            Said as written: part 1 of 2 (Apple Intelligence didn't answer in time); part 2 of 2 (not asked after that).
            """)
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

    @Test func aChunkTheModelAnswersWithNoWordsIsSaidAsWrittenAndNotKept() async throws {
        let harness = await harnessWithKokoro()
        let speakIPA = harness.model.speakIPA
        let message = message("Bach.")
        harness.transcriber.answers = [.success([])]
        speakIPA.toggle(message)
        #expect(await eventually { speakIPA.phase(for: message) == nil })
        #expect(harness.bed.kokoro.requests.map(\.text) == ["Bach."])
        #expect(speakIPA.note(for: message) == """
            0 of 1 words were said from Apple Intelligence's IPA.
            Said as written: part 1 of 1 (the model wrote no IPA for it).
            """)

        speakIPA.toggle(message)
        #expect(await eventually { speakIPA.phase(for: message) == nil })

        // Asked again: there was nothing to keep, and the next answer may have words.
        #expect(harness.transcriber.chunks == ["Bach.", "Bach."])
    }

    @Test func ipaWithASymbolKokoroLacksIsKeptAndSaidAgainTheSameWay() async throws {
        let harness = await harnessWithKokoro()
        let speakIPA = harness.model.speakIPA
        let message = message("Bach.")
        harness.transcriber.answers = [.success([TranscribedWord(word: "Bach", ipa: "bɑx")])]
        speakIPA.toggle(message)
        #expect(await eventually { speakIPA.phase(for: message) == nil })

        speakIPA.toggle(message)
        #expect(await eventually { speakIPA.phase(for: message) == nil })

        #expect(harness.transcriber.chunks == ["Bach."])
        #expect(harness.bed.kokoro.requests.map { Set($0.pronunciations.values) } == [["bɑk"], ["bɑk"]])
    }
}
