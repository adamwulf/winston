import Foundation
import Testing
import TelegramLink
import TelegramLinkTestSupport
import VoiceLoop
import VoiceLoopTestSupport
import WinstonCore

// The real `VoiceLoop` on a `VoiceTestBed`: replies are spoken by the real synthesizer into an
// offline audio engine, and `bed.audio.playedFrames` is how much sound came out of the speaker.
// Speech takes real time, so the replies spoken here are short.

/// Voice mode: what is heard goes to the bot, and the bot's replies are spoken.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct VoiceModeTests {
    @Test func whatIsSaidIsSentToTheCurrentChatMarkedAsSpoken() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        model.pauseThreshold = 0.05

        await model.setVoiceMode(true)
        #expect(model.isVoiceMode)
        #expect(model.voiceLoop.state == .listening(partial: ""))
        harness.bed.recognizer.hear("Mark that read.", over: 0...1, isFinal: true, alternatives: ["Mark that red."])

        #expect(await eventually {
            harness.fake.requests.last == .sendText(chatID: 1, text: "🎙️ Mark that read. (alt: Mark that red.)")
        })
    }

    @Test func inVoiceModeAReplyInTheCurrentChatIsSpokenAndOneElsewhereIsNot() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        await model.setVoiceMode(true)

        // The other chat's reply is shown but not read out.
        harness.fake.receive(textMessage(id: 21, chatID: 2, "Starting the coordinator."))
        #expect(await eventually { model.messages[ChatID(2)]?.last?.text == "Starting the coordinator." })
        #expect(model.voiceLoop.state == .listening(partial: ""))
        #expect(harness.bed.audio.playedFrames == 0)

        harness.fake.receive(textMessage(id: 12, chatID: 1, "Done."))
        #expect(await eventually { model.voiceLoop.state == .speaking })
        #expect(await eventually { model.voiceLoop.state == .listening(partial: "") })
        #expect(harness.bed.audio.playedFrames > 0)
    }

    @Test func turningVoiceModeOnStartsListeningAndTurningItOffStops() async throws {
        let harness = Harness()
        let model = harness.model

        await model.setVoiceMode(true)

        #expect(model.isVoiceMode)
        #expect(!model.isStartingVoice)
        #expect(model.voiceLoop.state == .listening(partial: ""))
        #expect(harness.bed.recognizers.count == 1)
        #expect(harness.bed.recognizer.isStarted)

        await model.setVoiceMode(false)

        #expect(!model.isVoiceMode)
        #expect(model.voiceLoop.state == .off)
        #expect(await eventually { harness.bed.recognizer.isCancelled })
    }

    @Test func withoutTheMicrophoneVoiceModeStaysOffAndSaysWhy() async throws {
        let harness = Harness()
        harness.bed.permissionError = .microphonePermissionDenied
        let model = harness.model

        await model.setVoiceMode(true)

        #expect(!model.isVoiceMode)
        #expect(!model.isStartingVoice)
        #expect(model.errorMessage == userMessage(for: VoiceLoopError.microphonePermissionDenied))
        #expect(model.voiceLoop.state == .off)
        #expect(harness.bed.recognizers.isEmpty)
    }

    @Test func turningVoiceModeOffWhileItIsStartingLeavesItOff() async throws {
        let harness = Harness()
        let model = harness.model
        harness.bed.whenRequestingPermissions = { await model.setVoiceMode(false) }

        await model.setVoiceMode(true)

        #expect(!model.isVoiceMode)
        #expect(!model.isStartingVoice)
        #expect(model.voiceLoop.state == .off)
        #expect(harness.bed.recognizers.allSatisfy { !$0.isStarted })
        try await settle()
        #expect(model.voiceLoop.state == .off)
    }

    @Test func turningVoiceModeOnAgainWhileItIsStartingStartsOneSession() async throws {
        let harness = Harness()
        let model = harness.model
        var startingAfterSecondTap = false
        harness.bed.whenRequestingPermissions = {
            await model.setVoiceMode(true)
            startingAfterSecondTap = model.isStartingVoice
        }

        await model.setVoiceMode(true)

        // The first start still owned the flag after the second tap, and cleared it when done.
        #expect(startingAfterSecondTap)
        #expect(model.isVoiceMode)
        #expect(!model.isStartingVoice)
        #expect(model.voiceLoop.state == .listening(partial: ""))
        #expect(harness.bed.recognizers.count == 1)
        #expect(harness.bed.audio.engines.count == 1)
    }

    @Test func aQuickOffAndOnWhileStartingLeavesVoiceModeListening() async throws {
        let harness = Harness()
        let model = harness.model
        var permissionRequests = 0
        harness.bed.whenRequestingPermissions = {
            permissionRequests += 1
            // The mic button is tapped off and on again during the first start only.
            guard permissionRequests == 1 else { return }
            await model.setVoiceMode(false)
            await model.setVoiceMode(true)
        }

        await model.setVoiceMode(true)

        // The off made the first start give up, so the model started again for the on. Before,
        // the button showed voice mode while the loop was off.
        #expect(permissionRequests == 2)
        #expect(model.isVoiceMode)
        #expect(!model.isStartingVoice)
        #expect(model.voiceLoop.state == .listening(partial: ""))
        #expect(harness.bed.recognizer.isStarted)
        #expect(harness.bed.audio.engines.count == 1)
    }

    @Test func turningVoiceModeOnWhileListeningChangesNothing() async throws {
        let harness = Harness()
        let model = harness.model
        await model.setVoiceMode(true)

        await model.setVoiceMode(true)

        #expect(model.isVoiceMode)
        #expect(model.voiceLoop.state == .listening(partial: ""))
        #expect(harness.bed.recognizers.count == 1)
        #expect(harness.bed.audio.engines.count == 1)
        #expect(!harness.bed.recognizer.isCancelled)
    }

    @Test func aVoicePreviewInVoiceModeIsSpokenThroughTheLoop() async throws {
        let harness = Harness()
        let model = harness.model
        await model.setVoiceMode(true)

        model.previewVoice()

        #expect(model.voiceLoop.state == .speaking)
        #expect(await eventually { harness.bed.audio.playedFrames > 0 })
    }

    @Test func aKokoroVoiceIsPreviewedOnceItsModelIsReadyAndNotBefore() async throws {
        let harness = Harness()
        harness.bed.kokoro.loadBehavior = .waits
        let model = harness.model
        await model.setVoiceMode(true)
        model.voiceIdentifier = "kokoro.af_heart"

        // Still downloading: the preview would only be the system voice.
        model.previewVoice()
        #expect(model.voiceLoop.state == .listening(partial: ""))

        harness.bed.kokoro.finishLoading(succeeding: true)
        #expect(await eventually { model.voiceLoop.kokoroModelState == .ready })
        model.previewVoice()

        #expect(model.voiceLoop.state == .speaking)
        #expect(await eventually { model.voiceLoop.state == .listening(partial: "") })
        #expect(!harness.bed.kokoro.requests.isEmpty)
        #expect(harness.bed.kokoro.requests.allSatisfy { $0.voice == "af_heart" })
    }

    @Test func pickingAKokoroVoiceThatIsNotReadyCutsOffThePreviewBefore() async throws {
        let harness = Harness()
        harness.bed.kokoro.loadBehavior = .waits
        let model = harness.model
        model.previewVoice()
        let engine = try #require(harness.bed.audio.engines.last)
        #expect(engine.isRunning)

        model.voiceIdentifier = "kokoro.af_heart"
        model.previewVoice()

        // The system voice's preview stopped, and nothing took its place.
        #expect(!engine.isRunning)
        #expect(harness.bed.audio.engines.count == 1)
        harness.bed.kokoro.finishLoading(succeeding: true)
    }

    @Test func inVoiceModePickingAKokoroVoiceThatIsNotReadyCutsOffThePreviewBefore() async throws {
        let harness = Harness()
        harness.bed.kokoro.loadBehavior = .waits
        let model = harness.model
        await model.setVoiceMode(true)
        model.previewVoice()
        #expect(model.voiceLoop.state == .speaking)

        model.voiceIdentifier = "kokoro.af_heart"
        model.previewVoice()

        #expect(model.voiceLoop.state == .listening(partial: ""))
        harness.bed.kokoro.finishLoading(succeeding: true)
    }

    @Test func outsideVoiceModeAKokoroVoiceIsPreviewedOnceItsModelIsReadyAndNotBefore() async throws {
        let harness = Harness()
        harness.bed.kokoro.loadBehavior = .waits
        let model = harness.model
        model.voiceIdentifier = "kokoro.af_heart"

        // Still downloading: nothing plays, not even the system voice.
        model.previewVoice()
        try await settle()
        #expect(harness.bed.audio.engines.isEmpty)

        harness.bed.kokoro.finishLoading(succeeding: true)
        #expect(await eventually { model.voiceLoop.kokoroModelState == .ready })
        model.previewVoice()

        // The preview player's own engine plays Kokoro, and stops once it has played.
        #expect(model.voiceLoop.state == .off)
        let engine = try #require(harness.bed.audio.engines.last)
        #expect(await eventually { !engine.isRunning })
        #expect(harness.bed.audio.playedFrames > 0)
        #expect(!harness.bed.kokoro.requests.isEmpty)
        #expect(harness.bed.kokoro.requests.allSatisfy { $0.voice == "af_heart" })
    }
}

/// Which of the bot's messages voice mode reads out.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SpokenMessageTests {
    @Test func aPhotoWithoutACaptionIsAnnounced() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        await model.setVoiceMode(true)

        harness.fake.receive(photoMessage(id: 12, chatID: 1, sizes: [photoSize(fileID: 5, width: 1280, height: 960)]))

        #expect(await eventually { harness.bed.audio.playedFrames > 0 })
        #expect(model.currentMessages.last?.text == "")
        #expect(model.currentMessages.last?.attachment == .photo(FileRef(id: 5, localPath: nil), width: 1280, height: 960))
    }

    @Test func aDocumentIsAnnounced() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        await model.setVoiceMode(true)

        harness.fake.receive(documentMessage(
            id: 12,
            chatID: 1,
            document: file(id: 6, size: 2048),
            fileName: "notes.txt",
            mimeType: "text/plain"
        ))

        #expect(await eventually { harness.bed.audio.playedFrames > 0 })
        #expect(model.currentMessages.last?.attachment == .document(
            FileRef(id: 6, localPath: nil),
            fileName: "notes.txt",
            mimeType: "text/plain",
            size: 2048
        ))
    }

    @Test func aMessageWithNoTextAndNoAttachmentIsNotSpoken() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        await model.setVoiceMode(true)

        // A photo TDLib sent no sizes for, and no caption.
        harness.fake.receive(photoMessage(id: 12, chatID: 1, sizes: []))

        #expect(await eventually { model.currentMessages.last?.id == MessageID(12) })
        #expect(model.currentMessages.last?.text == "")
        #expect(model.currentMessages.last?.attachment == nil)
        #expect(model.voiceLoop.state == .listening(partial: ""))
        try await settle()
        #expect(harness.bed.audio.playedFrames == 0)
    }

    @Test func anOutgoingMessageIsNotReadBack() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        await model.setVoiceMode(true)

        #expect(await model.sendText("Run the tests."))
        #expect(await eventually { model.currentMessages.last?.text == "Run the tests." })
        let pending = try #require(model.currentMessages.last)
        #expect(pending.isOutgoing)
        harness.fake.confirmSend(of: pending.id.rawValue, in: 1, as: 13)
        #expect(await eventually { model.currentMessages.last?.id == MessageID(13) })

        #expect(model.voiceLoop.state == .listening(partial: ""))
        try await settle()
        #expect(harness.bed.audio.playedFrames == 0)
    }

    @Test func aMessageThatReplacesOneAlreadyShownIsNotSpokenAgain() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        await model.setVoiceMode(true)
        harness.fake.receive(textMessage(id: 12, chatID: 1, "Done."))
        // Spoken, and finished.
        #expect(await eventually {
            harness.bed.audio.playedFrames > 0 && model.voiceLoop.state == .listening(partial: "")
        })
        let played = harness.bed.audio.playedFrames

        harness.fake.receive(textMessage(id: 12, chatID: 1, "Done, all green."))

        #expect(await eventually { model.currentMessages.last?.text == "Done, all green." })
        #expect(model.currentMessages.map(\.id) == [MessageID(10), MessageID(11), MessageID(12)])
        #expect(model.voiceLoop.state == .listening(partial: ""))
        try await settle()
        #expect(harness.bed.audio.playedFrames == played)
    }

    @Test func nothingIsSpokenOnceVoiceModeIsOff() async throws {
        let harness = Harness.withTwoBots()
        #expect(await harness.startAndLoadChats())
        let model = harness.model
        await model.setVoiceMode(true)
        await model.setVoiceMode(false)

        harness.fake.receive(textMessage(id: 12, chatID: 1, "Done."))

        #expect(await eventually { model.currentMessages.last?.text == "Done." })
        #expect(model.voiceLoop.state == .off)
        try await settle()
        #expect(harness.bed.audio.playedFrames == 0)
    }
}

/// The chime when the bot puts a 👍 on a message, in voice mode. These harnesses turn the sound
/// cues on; a cue renders in a few milliseconds, so `settle()` lets one finish.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ReactionChimeTests {
    /// Two bots with their chats loaded and the sound cues on, in voice mode once the start cue
    /// has played, or in text mode.
    private func twoBots(inVoiceMode: Bool = true) async throws -> Harness {
        let harness = Harness.withTwoBots(soundCues: true)
        #expect(await harness.startAndLoadChats())
        if inVoiceMode {
            await harness.model.setVoiceMode(true)
            #expect(await eventually { harness.bed.audio.playedFrames > 0 })
            try await settle()
        }
        return harness
    }

    @Test func theBotsThumbsUpInTheCurrentChatChimes() async throws {
        let harness = try await twoBots()
        let model = harness.model
        let played = harness.bed.audio.playedFrames

        try harness.fake.botReacts("👍", to: 11, in: 1)

        #expect(await eventually {
            model.latestIncomingMessage?.reactions == [Reaction(emoji: "👍", count: 1, isChosen: false)]
        })
        #expect(await eventually { harness.bed.audio.playedFrames > played })
        #expect(model.voiceLoop.state == .listening(partial: ""))
    }

    @Test func adamsOwnThumbsUpIsSilentButTheBotsBesideItChimes() async throws {
        let harness = try await twoBots()
        let model = harness.model
        let played = harness.bed.audio.playedFrames

        await model.toggleThumbsUp(on: try #require(model.latestIncomingMessage))
        #expect(await eventually { model.latestIncomingMessage?.hasMyThumbsUp == true })
        try await settle()
        #expect(harness.bed.audio.playedFrames == played)

        try harness.fake.botReacts("👍", to: 11, in: 1)
        #expect(await eventually {
            model.latestIncomingMessage?.reactions == [Reaction(emoji: "👍", count: 2, isChosen: true)]
        })
        #expect(await eventually { harness.bed.audio.playedFrames > played })

        // Adam taking his back leaves the bot's, and is silent too.
        try await settle()
        let playedWithBoth = harness.bed.audio.playedFrames
        await model.toggleThumbsUp(on: try #require(model.latestIncomingMessage))
        #expect(await eventually {
            model.latestIncomingMessage?.reactions == [Reaction(emoji: "👍", count: 1, isChosen: false)]
        })
        try await settle()
        #expect(harness.bed.audio.playedFrames == playedWithBoth)
    }

    @Test func theBotsThumbsUpIsSilentInTextMode() async throws {
        let harness = try await twoBots(inVoiceMode: false)
        let model = harness.model

        try harness.fake.botReacts("👍", to: 11, in: 1)

        #expect(await eventually {
            model.latestIncomingMessage?.reactions == [Reaction(emoji: "👍", count: 1, isChosen: false)]
        })
        try await settle()
        #expect(harness.bed.audio.playedFrames == 0)
        #expect(harness.bed.audio.engines.isEmpty)
    }

    @Test func theBotsThumbsUpInAnotherChatIsSilent() async throws {
        let harness = try await twoBots()
        let model = harness.model
        let played = harness.bed.audio.playedFrames

        try harness.fake.botReacts("👍", to: 20, in: 2)

        #expect(await eventually {
            model.messages[ChatID(2)]?.last?.reactions == [Reaction(emoji: "👍", count: 1, isChosen: false)]
        })
        try await settle()
        #expect(harness.bed.audio.playedFrames == played)
    }

    @Test func anotherEmojiFromTheBotIsSilent() async throws {
        let harness = try await twoBots()
        let model = harness.model
        let played = harness.bed.audio.playedFrames

        try harness.fake.botReacts("👀", to: 11, in: 1)

        #expect(await eventually {
            model.latestIncomingMessage?.reactions == [Reaction(emoji: "👀", count: 1, isChosen: false)]
        })
        try await settle()
        #expect(harness.bed.audio.playedFrames == played)
    }

    @Test func theBotsThumbsUpOnAMessageThatIsNotLoadedIsSilent() async throws {
        let harness = try await twoBots()
        let model = harness.model
        harness.fake.addHistory([textMessage(id: 5, chatID: 1, "An old reply.")])
        let played = harness.bed.audio.playedFrames

        try harness.fake.botReacts("👍", to: 5, in: 1)
        // Events arrive in order, so once this one shows, the reaction was handled.
        harness.fake.setTyping(true, in: 1)

        #expect(await eventually { model.isBotTyping })
        try await settle()
        #expect(harness.bed.audio.playedFrames == played)
        #expect(!model.currentMessages.contains { $0.id == MessageID(5) })
    }
}

/// The voice settings: how long a pause ends what Adam says, and the voice replies are read in.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct VoiceSettingsTests {
    @Test func theDefaultsAreAPauseOfOnePointTwoSecondsAndTheDefaultVoice() async throws {
        let harness = Harness()
        let model = harness.model

        #expect(model.pauseThreshold == 1.2)
        #expect(model.voiceIdentifier == nil)
        #expect(model.voiceLoop.pauseThreshold == .seconds(1.2))
        #expect(model.voiceLoop.voiceIdentifier == nil)
    }

    @Test func settingsAreSavedAppliedToTheLoopAndRestoredOnRelaunch() async throws {
        let harness = Harness()
        let model = harness.model
        let voice = "com.apple.voice.compact.en-US.Samantha"

        model.pauseThreshold = 0.8
        model.voiceIdentifier = voice

        #expect(harness.defaults.object(forKey: "pauseThreshold") as? Double == 0.8)
        #expect(harness.defaults.string(forKey: "voiceIdentifier") == voice)
        #expect(model.voiceLoop.pauseThreshold == .seconds(0.8))
        #expect(model.voiceLoop.voiceIdentifier == voice)
        let relaunched = harness.relaunchedModel()
        #expect(relaunched.pauseThreshold == 0.8)
        #expect(relaunched.voiceIdentifier == voice)
        #expect(relaunched.voiceLoop.pauseThreshold == .seconds(0.8))
        #expect(relaunched.voiceLoop.voiceIdentifier == voice)
        // A system voice needs no Kokoro model.
        #expect(harness.bed.kokoro.loads == 0)
        #expect(relaunched.voiceLoop.kokoroModelState == .notLoaded)

        // Back to the default voice.
        model.voiceIdentifier = nil

        #expect(harness.defaults.object(forKey: "voiceIdentifier") == nil)
        #expect(model.voiceLoop.voiceIdentifier == nil)
        #expect(harness.relaunchedModel().voiceIdentifier == nil)
    }

    @Test func choosingAKokoroVoiceDownloadsItsModelAndARelaunchLoadsItAtOnce() async throws {
        let harness = Harness()
        let model = harness.model

        model.voiceIdentifier = "kokoro.af_heart"

        #expect(harness.defaults.string(forKey: "voiceIdentifier") == "kokoro.af_heart")
        #expect(model.voiceLoop.voiceIdentifier == "kokoro.af_heart")
        #expect(await eventually { model.voiceLoop.kokoroModelState == .ready })
        #expect(harness.bed.kokoro.loads == 1)
        let relaunched = harness.relaunchedModel()
        #expect(relaunched.voiceLoop.kokoroModelState == .loading)
        #expect(await eventually { relaunched.voiceLoop.kokoroModelState == .ready })
    }

    @Test func aKokoroVoiceChosenInAnotherLanguageIsKeptButNotUsedAfterARelaunch() async throws {
        let harness = Harness()
        harness.model.voiceIdentifier = "kokoro.af_heart"
        let british = VoiceTestBed()
        british.languageCode = "en-GB"

        let relaunched = harness.relaunchedModel(on: british)

        // Still saved, for when American English is back.
        #expect(relaunched.voiceIdentifier == "kokoro.af_heart")
        #expect(harness.defaults.string(forKey: "voiceIdentifier") == "kokoro.af_heart")
        // But as good as no choice: no model loads, and the preview is the best system voice.
        #expect(relaunched.voiceLoop.chosenVoice == nil)
        relaunched.previewVoice()
        let engine = try #require(british.audio.engines.last)
        #expect(await eventually { !engine.isRunning })
        #expect(british.audio.playedFrames > 0)
        #expect(british.kokoro.loads == 0)
        #expect(british.kokoro.requests.isEmpty)
        #expect(relaunched.voiceLoop.kokoroModelState == .notLoaded)
    }

    @Test func aLaunchADayAfterTheLastKokoroVoiceWasUnchosenDeletesItsModel() async throws {
        let harness = Harness()
        let model = harness.model
        model.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { model.voiceLoop.kokoroModelState == .ready })
        model.voiceIdentifier = nil

        // Relaunched on the same device, which keeps the model and the record of when it was
        // last unchosen.
        harness.bed.now += 23 * 60 * 60
        let early = harness.relaunchedModel(on: harness.bed)
        try await settle()
        #expect(harness.bed.kokoro.isStored)

        harness.bed.now += 60 * 60
        let later = harness.relaunchedModel(on: harness.bed)
        #expect(await eventually { !harness.bed.kokoro.isStored })
        #expect(early.voiceLoop.kokoroModelState == .notLoaded)
        #expect(later.voiceLoop.kokoroModelState == .notLoaded)
    }

    @Test func aModelLeftByAnEarlierVersionIsDeletedADayAfterTheFirstLaunchNotAtIt() async throws {
        let harness = Harness()
        let bed = VoiceTestBed()
        // Downloaded by a version that kept no record of when it was last used.
        bed.kokoro.isStored = true

        let launched = harness.relaunchedModel(on: bed)
        try await settle()
        #expect(bed.kokoro.isStored)
        #expect(bed.kokoroUnchosenSince == bed.now)

        bed.now += 24 * 60 * 60
        let relaunched = harness.relaunchedModel(on: bed)
        #expect(await eventually { !bed.kokoro.isStored })
        #expect(launched.voiceLoop.kokoroModelState == .notLoaded)
        #expect(relaunched.voiceLoop.kokoroModelState == .notLoaded)
    }

    @Test func aLaunchWithAKokoroVoiceKeepsItsModelHoweverOldTheRecord() async throws {
        let harness = Harness()
        harness.model.voiceIdentifier = "kokoro.af_heart"
        let bed = VoiceTestBed()
        bed.kokoro.isStored = true
        bed.kokoroUnchosenSince = bed.now - 7 * 24 * 60 * 60

        let relaunched = harness.relaunchedModel(on: bed)

        #expect(await eventually { relaunched.voiceLoop.kokoroModelState == .ready })
        try await settle()
        #expect(bed.kokoro.removals == 0)
        #expect(bed.kokoro.isStored)
        #expect(bed.kokoroUnchosenSince == nil)
    }

    @Test func repliesAreSpokenAtNormalSpeedAndOtherAudioPausesByDefault() async throws {
        let harness = Harness()
        let model = harness.model

        #expect(model.speechRate == VoiceLoop.defaultSpeechRate)
        #expect(model.pausesOtherAudio)
        #expect(model.voiceLoop.speechRate == VoiceLoop.defaultSpeechRate)
        #expect(model.voiceLoop.pausesOtherAudio)
    }

    @Test func theSpeakingSpeedAndPauseOtherAudioAreSavedAppliedAndRestored() async throws {
        let harness = Harness()
        let model = harness.model
        let fastest = VoiceLoop.speechRates.upperBound

        model.speechRate = fastest
        model.pausesOtherAudio = false

        #expect(harness.defaults.object(forKey: "speechRate") as? Float == fastest)
        #expect(harness.defaults.object(forKey: "pausesOtherAudio") as? Bool == false)
        #expect(model.voiceLoop.speechRate == fastest)
        #expect(!model.voiceLoop.pausesOtherAudio)
        let relaunched = harness.relaunchedModel()
        #expect(relaunched.speechRate == fastest)
        #expect(!relaunched.pausesOtherAudio)
        #expect(relaunched.voiceLoop.speechRate == fastest)
        #expect(!relaunched.voiceLoop.pausesOtherAudio)
    }

    @Test func repliesAreSpokenAtTheVoicesOwnPitchByDefault() async throws {
        let harness = Harness()
        let model = harness.model

        #expect(model.speechPitch == VoiceLoop.defaultSpeechPitch)
        #expect(model.voiceLoop.speechPitch == VoiceLoop.defaultSpeechPitch)
    }

    @Test func theSpeakingPitchIsSavedAppliedAndRestored() async throws {
        let harness = Harness()
        let model = harness.model
        let highest = VoiceLoop.speechPitches.upperBound

        model.speechPitch = highest

        #expect(harness.defaults.object(forKey: "speechPitch") as? Float == highest)
        #expect(model.voiceLoop.speechPitch == highest)
        let relaunched = harness.relaunchedModel()
        #expect(relaunched.speechPitch == highest)
        #expect(relaunched.voiceLoop.speechPitch == highest)
    }

    @Test func turningPauseOtherAudioOffInVoiceModeRebuildsTheEngineAndKeepsListening() async throws {
        let harness = Harness()
        let model = harness.model
        await model.setVoiceMode(true)

        model.pausesOtherAudio = false

        #expect(model.isVoiceMode)
        #expect(model.voiceLoop.state == .listening(partial: ""))
        #expect(await eventually { harness.bed.recognizers.count == 2 && harness.bed.recognizer.isStarted })
        #expect(harness.bed.audio.engines.count == 2)
        #expect(model.voiceLoop.state == .listening(partial: ""))
    }
}
