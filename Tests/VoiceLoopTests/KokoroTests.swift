import AVFoundation
import Foundation
import Observation
import Synchronization
import Testing
@testable import VoiceLoop
import VoiceLoopTestSupport

// Kokoro voices. The session tests run the real `VoiceLoop` on a `VoiceTestBed`, whose
// `FakeKokoro` renders each sentence as a 0.2 s tone, so `bed.audio.playedFrames` tells
// Kokoro's audio from the system voice's.

/// Runs the tests of the suites it marks one at a time, across those suites. Each test bed
/// renders its audio on the main actor, which every suite in the process shares, and the
/// listening tests time their pauses by the clock: with these suites' loops all rendering at
/// once as well, the main actor fell behind and `aVoiceStillTalkingKeepsTheUtteranceOpen` heard
/// its pretend voice too late.
private struct OneVoiceLoopAtATime: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        await turns.take()
        do {
            try await function()
        } catch {
            await turns.pass()
            throw error
        }
        await turns.pass()
    }
}

/// Hands out turns in the order they are asked for.
private actor Turns {
    private var isTaken = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func take() async {
        guard isTaken else {
            isTaken = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func pass() {
        if waiting.isEmpty {
            isTaken = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

private let turns = Turns()

extension Trait where Self == OneVoiceLoopAtATime {
    /// See `OneVoiceLoopAtATime`.
    fileprivate static var oneVoiceLoopAtATime: Self { Self() }
}

/// What the speaker plays for one sentence from `FakeKokoro`, at 48 kHz.
private let fakeSentenceFrames = Int(FakeKokoro.secondsPerSentence * 48_000)

/// The placeholder numbered `number` (see `PhoneticPlaceholders`): in lowercase, as Kokoro is
/// given its phonemes, or with a `capital`, as a message holds it for a word that has one. A loop
/// gives them out from 0, in the order it first meets each word and phonemes.
private func placeholder(_ number: Int, capital: Bool = false) -> String {
    let placeholder = PhoneticPlaceholders.placeholder(number: number)
    return capital ? placeholder.prefix(1).uppercased() + placeholder.dropFirst() : placeholder
}

/// Audio far enough along the timeline to be new, whatever has been consumed.
private let later: ClosedRange<Double> = 1_000_000...1_000_001

/// A started loop with a short pause threshold, so utterances finish quickly.
@MainActor
private func startedLoop(on bed: VoiceTestBed) async throws -> VoiceLoop {
    let loop = bed.makeLoop()
    loop.pauseThreshold = .milliseconds(50)
    try await loop.start()
    return loop
}

/// A started loop speaking with the Heart voice, its model loaded.
@MainActor
private func loopSpeakingWithKokoro(on bed: VoiceTestBed) async throws -> VoiceLoop {
    let loop = try await startedLoop(on: bed)
    loop.voiceIdentifier = "kokoro.af_heart"
    #expect(await eventually { loop.kokoroModelState == .ready })
    return loop
}

/// Lets queued main-actor work and the audio engine run for a moment, before checking that
/// something did NOT happen.
private func settle(_ duration: Duration = .milliseconds(250)) async throws {
    try await Task.sleep(for: duration)
}

/// The pitch shift that speech plays through in `engine`.
@MainActor
private func pitchShift(in engine: AVAudioEngine?) throws -> AVAudioUnitTimePitch {
    let shifts = try #require(engine).attachedNodes.compactMap { $0 as? AVAudioUnitTimePitch }
    #expect(shifts.count == 1)
    return try #require(shifts.first)
}

/// How often the sound out of the speaker crossed zero, per second of sound. `FakeKokoro`'s
/// tone crosses zero 880 times a second: 1760 an octave up, 440 an octave down.
@MainActor
private func zeroCrossingsPerSecond(on bed: VoiceTestBed) -> Double {
    Double(bed.audio.playedZeroCrossings) / Double(bed.audio.playedFrames) * 48_000
}

/// Says `text` and waits until the loop has finished. Returns how much sound came out.
@MainActor
private func framesPlayed(saying text: String, by loop: VoiceLoop, on bed: VoiceTestBed) async -> Int {
    let before = bed.audio.playedFrames
    loop.speak(text)
    #expect(loop.state == .speaking)
    #expect(await eventually { loop.state == .listening(partial: "") })
    // The pitch shift pulls the player a render pass ahead of the speaker, so the reply's
    // last pass is rendered just after it counts as played. Waits for twice that, counted in
    // passes, not time: a busy machine can take far longer than usual to render them.
    #expect(await renderPassesGoBy(2, on: bed))
    return bed.audio.playedFrames - before
}

// MARK: - Speaking

@MainActor
@Suite(.serialized, .oneVoiceLoopAtATime, .timeLimit(.minutes(1)))
struct KokoroSpeakingTests {
    @Test func aKokoroVoiceSpeaksEachSentenceWithKokoroOnceItsModelIsReady() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }

        let played = await framesPlayed(saying: "Hello there. How are you today?", by: loop, on: bed)

        #expect(bed.kokoro.requests == [
            FakeKokoro.Request(text: "Hello there.", voice: "af_heart", speed: 1),
            FakeKokoro.Request(text: "How are you today?", voice: "af_heart", speed: 1),
        ])
        // Both sentences played, and nothing else did.
        let expected = 2 * fakeSentenceFrames
        #expect(abs(played - expected) <= expected / 20)
    }

    @Test func kokoroIsGivenNumbersAsWords() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }

        _ = await framesPlayed(saying: "It costs $20, up 5%. Meet me at 10:30 on the 3rd.", by: loop, on: bed)

        #expect(bed.kokoro.requests.map(\.text) == [
            "It costs twenty dollars, up five percent.",
            "Meet me at ten thirty on the third.",
        ])
    }

    @Test func kokoroIsGivenAcronymsItsDictionaryLacksSpelledOut() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.dictionary = ["not", "nasa"]
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }

        _ = await framesPlayed(saying: "The API is NOT up 5% at NASA.", by: loop, on: bed)
        // The dictionary is asked for again when the model is loaded again.
        loop.voiceIdentifier = nil
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { loop.kokoroModelState == .ready })
        _ = await framesPlayed(saying: "Two PRs.", by: loop, on: bed)

        #expect(bed.kokoro.requests.map(\.text) == ["The eh P eye is NOT up five percent at NASA.", "Two P Rs."])
    }

    @Test func pronunciationsAreSaidInPlaceOfTheirWordsBeforeAcronymsAreSpelledOut() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.dictionary = ["valid"]
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }
        loop.pronunciations = [Pronunciation(word: "JSON", replacement: "Jason")]

        _ = await framesPlayed(saying: "The JSON is valid, and so is the XML. Not json.", by: loop, on: bed)

        #expect(bed.kokoro.requests.map(\.text) == ["The Jason is valid, and so is the X M L.", "Not json."])
    }

    @Test func kokoroIsGivenAnIPAWordAsAPlaceholderWithItsPhonemes() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.dictionary = ["reads"]
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }
        loop.pronunciations = [
            Pronunciation(word: "Kokoro", replacement: " kˈOkəɹO ", mode: .phonetic),
            Pronunciation(word: "JSON", replacement: "Jason"),
        ]

        _ = await framesPlayed(saying: "Kokoro reads JSON. Not kokoro. Kokoro's 2nd API.", by: loop, on: bed)

        let requests = bed.kokoro.requests
        let placeholder = try #require(requests.first?.pronunciations.first?.key)
        #expect(placeholder.allSatisfy { $0.isASCII && $0.isLowercase })
        #expect(placeholder != "kokoro")
        let phonemes = [placeholder: "kˈOkəɹO"]
        // With the word's capital, so the third sentence is still a sentence of its own.
        let p = placeholder.prefix(1).uppercased() + placeholder.dropFirst()
        #expect(requests == [
            FakeKokoro.Request(text: "\(p) reads Jason.", voice: "af_heart", speed: 1, pronunciations: phonemes),
            FakeKokoro.Request(text: "Not kokoro.", voice: "af_heart", speed: 1),
            FakeKokoro.Request(text: "\(p)'s second eh P eye.", voice: "af_heart", speed: 1, pronunciations: phonemes),
        ])
    }

    @Test func aReplyQueuedBeforeItsIPAPronunciationWasRemovedStillGetsItsPhonemes() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }
        loop.pronunciations = [Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic)]
        loop.speak("The first one.")
        loop.speak("Kokoro is next.")

        loop.pronunciations = []

        #expect(await eventually { loop.state == .listening(partial: "") })
        let requests = bed.kokoro.requests
        #expect(requests.count == 2)
        let placeholder = try #require(requests.last?.pronunciations.first?.key)
        #expect(requests.last == FakeKokoro.Request(
            text: placeholder.prefix(1).uppercased() + placeholder.dropFirst() + " is next.",
            voice: "af_heart",
            speed: 1,
            pronunciations: [placeholder: "kˈOkəɹO"]
        ))
    }

    @Test func aSystemVoiceSaysIPAWordsAsWritten() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        loop.pronunciations = [
            Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic),
            Pronunciation(word: "JSON", replacement: "Jason"),
            Pronunciation(word: "New York City", replacement: "nˈu jˈɔɹk sˈɪɾi", mode: .phonetic),
            Pronunciation(word: "Yahoo!", replacement: "jˈɑhu", mode: .phonetic),
            Pronunciation(word: "Mr.", replacement: "mˈɪstəɹ", mode: .phonetic),
            Pronunciation(word: "👏", replacement: "klˈæp", mode: .phonetic),
            Pronunciation(word: "👍", replacement: "thumbs up"),
        ]
        let replies = [
            // A word beside a respelling.
            "Kokoro reads JSON.",
            // Several words, a placeholder each.
            "I love New York City.",
            // Sentence punctuation kept after the placeholders: said once.
            "I used Yahoo! Then I switched.",
            // A full stop that ends no sentence, part of the placeholders.
            "Mr. Smith paid 3.50 for it.",
            // Placeholders side by side, a space between.
            "Done 👏👏👍👏",
        ]

        for reply in replies {
            loop.speak(reply)
            // The system voice is given the reply as it starts; it needn't be heard.
            loop.stopSpeaking()
        }

        #expect(bed.systemVoiceTexts == [
            "Kokoro reads Jason.",
            "I love New York City.",
            "I used Yahoo! Then I switched.",
            "Mr. Smith paid 3.50 for it.",
            "Done 👏 👏 thumbs up 👏",
        ])
        #expect(bed.kokoro.requests.isEmpty)
    }

    @Test func whenKokoroFailsMidReplyTheSystemVoiceSaysTheRestWithTheIPAWord() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }
        loop.pronunciations = [Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic)]
        bed.kokoro.failingRequest = 1

        loop.speak("Kokoro one. Kokoro two. Kokoro three.")

        #expect(await eventually { !bed.systemVoiceTexts.isEmpty })
        loop.stopSpeaking()
        #expect(bed.kokoro.requests.count == 2)
        #expect(bed.kokoro.requests.allSatisfy { $0.pronunciations.count == 1 })
        #expect(bed.systemVoiceTexts == ["Kokoro two. Kokoro three."])
    }

    @Test func whenTheModelIsFreedMidReplyTheSystemVoiceSaysTheRestWithTheIPAWord() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }
        loop.pronunciations = [Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic)]
        bed.kokoro.holdsSynthesis = true
        loop.speak("The first sentence here. Kokoro says the second.")
        #expect(await eventually { bed.kokoro.heldSyntheses == 1 })

        loop.voiceIdentifier = nil
        bed.kokoro.holdsSynthesis = false
        bed.kokoro.releaseSyntheses()

        #expect(await eventually { !bed.systemVoiceTexts.isEmpty })
        loop.stopSpeaking()
        #expect(bed.systemVoiceTexts == ["Kokoro says the second."])
    }

    /// Says `reply` once the utterance being heard is sent: it is queued now, as `change` is made,
    /// and waits without anything playing. Returns once the reply has started.
    private func speakAfterTheUtteranceInProgress(
        _ reply: String,
        by loop: VoiceLoop,
        on bed: VoiceTestBed,
        changingThePronunciations change: () -> Void,
        started: @MainActor () -> Bool
    ) async {
        bed.recognizer.hear("Hold on", over: 0...1)
        #expect(await eventually { loop.state == .listening(partial: "Hold on") })
        loop.speak(reply)
        // Queued, not started: it starts only after the change.
        #expect(!started())
        #expect(loop.state == .listening(partial: "Hold on"))
        change()
        #expect(await eventually(started))
    }

    @Test func aReplyQueuedBeforeItsIPAPronunciationWasRemovedIsStillSaidAsTheWordByASystemVoice() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        loop.pronunciations = [Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic)]

        await speakAfterTheUtteranceInProgress("Kokoro is next.", by: loop, on: bed) {
            loop.pronunciations = []
        } started: {
            !bed.systemVoiceTexts.isEmpty
        }

        loop.stopSpeaking()
        #expect(bed.systemVoiceTexts == ["Kokoro is next."])
    }

    @Test func aReplyQueuedBeforeItsIPAPronunciationWasRenamedIsStillSaidAsTheOldWordByASystemVoice() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        loop.pronunciations = [Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic)]

        await speakAfterTheUtteranceInProgress("Kokoro is next.", by: loop, on: bed) {
            loop.pronunciations[0].word = "Coco"
        } started: {
            !bed.systemVoiceTexts.isEmpty
        }

        loop.stopSpeaking()
        #expect(bed.systemVoiceTexts == ["Kokoro is next."])
    }

    @Test func whenKokoroFailsAfterAnIPAPronunciationWasRenamedTheSystemVoiceSaysTheOldWord() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }
        loop.pronunciations = [Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic)]
        bed.kokoro.holdsSynthesis = true
        bed.kokoro.failingRequest = 1
        loop.speak("The first one. Kokoro is next.")
        #expect(await eventually { bed.kokoro.heldSyntheses == 1 })

        loop.pronunciations[0].word = "Coco"
        bed.kokoro.holdsSynthesis = false
        bed.kokoro.releaseSyntheses()

        #expect(await eventually { !bed.systemVoiceTexts.isEmpty })
        loop.stopSpeaking()
        #expect(bed.kokoro.requests.last?.pronunciations == [placeholder(0): "kˈOkəɹO"])
        #expect(bed.systemVoiceTexts == ["Kokoro is next."])
    }

    @Test func aReplyQueuedBeforeItsIPAPhonemesChangedIsStillSaidWithTheOldOnes() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }
        loop.pronunciations = [Pronunciation(word: "Kokoro", replacement: "kˈOkəɹO", mode: .phonetic)]
        loop.speak("The first one.")
        loop.speak("Kokoro is next.")

        loop.pronunciations[0].replacement = "kəkˈɔɹO"
        loop.speak("Kokoro is last.")

        #expect(await eventually { loop.state == .listening(partial: "") })
        #expect(Array(bed.kokoro.requests.dropFirst()) == [
            FakeKokoro.Request(
                text: "\(placeholder(0, capital: true)) is next.",
                voice: "af_heart",
                speed: 1,
                pronunciations: [placeholder(0): "kˈOkəɹO"]
            ),
            FakeKokoro.Request(
                text: "\(placeholder(1, capital: true)) is last.",
                voice: "af_heart",
                speed: 1,
                pronunciations: [placeholder(1): "kəkˈɔɹO"]
            ),
        ])
    }

    @Test func kokoroIsGivenAPlaceholderForEachWordOfAnIPAPronunciationsPhonemes() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }
        loop.pronunciations = [Pronunciation(word: "New York City", replacement: "nˈu jˈɔɹk sˈɪɾi", mode: .phonetic)]

        _ = await framesPlayed(saying: "I love New York City.", by: loop, on: bed)

        // A space between them, so KokoroTTS can cut a long sentence there rather than inside one.
        #expect(bed.kokoro.requests == [FakeKokoro.Request(
            text: "I love \(placeholder(0, capital: true)) \(placeholder(1)) \(placeholder(2)).",
            voice: "af_heart",
            speed: 1,
            pronunciations: [placeholder(0): "nˈu", placeholder(1): "jˈɔɹk", placeholder(2): "sˈɪɾi"]
        )])
    }

    @Test func anIPAWordsSentencePunctuationStillEndsItsSentenceForKokoro() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }
        loop.pronunciations = [Pronunciation(word: "Yahoo!", replacement: "jˈɑhu", mode: .phonetic)]

        _ = await framesPlayed(saying: "I used Yahoo! Then I switched.", by: loop, on: bed)

        // Placeholders 0 stand for all of "Yahoo!"; 1 keep its "!" after them.
        #expect(bed.kokoro.requests == [
            FakeKokoro.Request(
                text: "I used \(placeholder(1, capital: true))!",
                voice: "af_heart",
                speed: 1,
                pronunciations: [placeholder(1): "jˈɑhu"]
            ),
            FakeKokoro.Request(text: "Then I switched.", voice: "af_heart", speed: 1),
        ])
    }

    @Test func anIPAWordsFullStopThatEndsNoSentenceMakesNoSentenceForKokoro() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }
        loop.pronunciations = [Pronunciation(word: "Mr.", replacement: "mˈɪstəɹ", mode: .phonetic)]

        _ = await framesPlayed(saying: "Mr. Smith paid 3.50 for it.", by: loop, on: bed)

        let requests = bed.kokoro.requests
        #expect(requests.count == 1)
        #expect(requests.first?.text.hasPrefix("\(placeholder(0, capital: true)) Smith paid ") == true)
        #expect(requests.first?.pronunciations == [placeholder(0): "mˈɪstəɹ"])
    }

    @Test func kokoroIsGivenEachOfIPAWordsSideBySideAsAPlaceholderOfItsOwn() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }
        loop.pronunciations = [
            Pronunciation(word: "👏", replacement: "klˈæp", mode: .phonetic),
            Pronunciation(word: "👍", replacement: "thumbs up"),
        ]

        _ = await framesPlayed(saying: "Done 👏👏👍👏", by: loop, on: bed)

        #expect(bed.kokoro.requests == [FakeKokoro.Request(
            text: "Done \(placeholder(0)) \(placeholder(0)) thumbs up \(placeholder(0))",
            voice: "af_heart",
            speed: 1,
            pronunciations: [placeholder(0): "klˈæp"]
        )])
    }

    @Test func choosingAKokoroVoiceLoadsTheModelOnceAndASystemVoiceDoesNot() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        let systemVoice = try #require(loop.voices.first { $0.engine == .system })

        loop.voiceIdentifier = systemVoice.id
        // Not a voice in the catalog, so the system voice speaks.
        loop.voiceIdentifier = "kokoro.no_such_voice"
        try await settle()
        #expect(bed.kokoro.loads == 0)
        #expect(loop.kokoroModelState == .notLoaded)

        loop.voiceIdentifier = "kokoro.af_nicole"
        #expect(loop.kokoroModelState == .loading)
        #expect(await eventually { loop.kokoroModelState == .ready })
        loop.voiceIdentifier = "kokoro.af_bella"
        try await loop.start()
        defer { loop.stop() }
        try await settle()

        #expect(bed.kokoro.loads == 1)
        #expect(loop.kokoroModelState == .ready)
    }

    @Test func untilTheModelIsReadyTheSystemVoiceSpeaks() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.loadBehavior = .waits
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(loop.kokoroModelState == .loading)
        #expect(await eventually { bed.kokoro.loads == 1 })
        bed.kokoro.reportDownloadProgress(0.5)
        #expect(await eventually { loop.kokoroModelState == .downloading(progress: 0.5) })

        // Not silent while the model downloads.
        #expect(await framesPlayed(saying: "Hi.", by: loop, on: bed) > 0)
        #expect(bed.kokoro.requests.isEmpty)

        bed.kokoro.finishLoading(succeeding: true)
        #expect(await eventually { loop.kokoroModelState == .ready })
        let played = await framesPlayed(saying: "Hi.", by: loop, on: bed)
        #expect(bed.kokoro.requests.map(\.text) == ["Hi."])
        #expect(abs(played - fakeSentenceFrames) <= fakeSentenceFrames / 20)
    }

    @Test func theLoadStageShowsWhileTheModelLoadsUntilItIsReadyOrFails() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.loadBehavior = .waits
        let loop = bed.makeLoop()

        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { bed.kokoro.loads == 1 })
        #expect(loop.kokoroLoadStage == nil)
        bed.kokoro.reportStage(.coreML)
        #expect(await eventually { loop.kokoroLoadStage?.stage == .coreML })
        #expect(loop.kokoroLoadStage?.since == bed.now)
        bed.now += 90
        bed.kokoro.reportStage(.warmingUp)
        #expect(await eventually { loop.kokoroLoadStage?.stage == .warmingUp })
        #expect(loop.kokoroLoadStage?.since == bed.now)
        bed.kokoro.finishLoading(succeeding: true)
        #expect(await eventually { loop.kokoroModelState == .ready })
        #expect(loop.kokoroLoadStage == nil)

        // A stage that arrives once the load is over is ignored.
        bed.kokoro.reportStage(.warmingUp)
        try await settle()
        #expect(loop.kokoroLoadStage == nil)

        loop.kokoroModelVariant = .masked5s
        #expect(await eventually { bed.kokoro.loads == 2 })
        bed.kokoro.reportStage(.vocabulary)
        #expect(await eventually { loop.kokoroLoadStage?.stage == .vocabulary })
        bed.kokoro.finishLoading(succeeding: false)
        #expect(await eventually { loop.kokoroModelState == .failed })
        #expect(loop.kokoroLoadStage == nil)
    }

    @Test func whenTheModelFailsTheSystemVoiceSpeaksAndVoiceModeOrARetryTriesAgain() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.loadBehavior = .fails
        let loop = bed.makeLoop()
        loop.pauseThreshold = .milliseconds(50)

        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { loop.kokoroModelState == .failed })
        // Starting voice mode tries again.
        try await loop.start()
        defer { loop.stop() }
        #expect(await eventually { bed.kokoro.loads == 2 && loop.kokoroModelState == .failed })

        #expect(await framesPlayed(saying: "Hi.", by: loop, on: bed) > 0)
        #expect(bed.kokoro.requests.isEmpty)

        // The settings screen's retry.
        bed.kokoro.loadBehavior = .succeeds
        loop.loadKokoroModel()
        #expect(await eventually { loop.kokoroModelState == .ready })
        #expect(bed.kokoro.loads == 3)
    }

    @Test func aSentenceThatFailsToRenderIsSpokenByTheSystemVoiceWithTheRest() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }
        bed.kokoro.failingRequest = 1

        let played = await framesPlayed(saying: "The first one. The second one. The third one.", by: loop, on: bed)

        // Kokoro gave up at the second sentence; the system voice said the second and third.
        #expect(bed.kokoro.requests.map(\.text) == ["The first one.", "The second one."])
        #expect(played > 2 * fakeSentenceFrames)
    }

    @Test func theSpeakingSpeedFollowsTheSpeechRate() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }

        loop.speechRate = VoiceLoop.speechRates.upperBound
        _ = await framesPlayed(saying: "Fast.", by: loop, on: bed)
        loop.speechRate = VoiceLoop.speechRates.lowerBound
        _ = await framesPlayed(saying: "Slow.", by: loop, on: bed)

        #expect(bed.kokoro.requests.map(\.speed) == [2, 0.5])
    }

    /// A reply of three sentences at `pitch`, on a test bed of its own. Returns the bed.
    private func bedAfterAReply(atPitch pitch: Float) async throws -> VoiceTestBed {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }
        loop.speechPitch = pitch
        _ = await framesPlayed(saying: "One more. Two more. Three more.", by: loop, on: bed)
        #expect(bed.kokoro.requests.count == 3)
        return bed
    }

    @Test func aKokoroReplyIsShiftedToTheChosenPitchAndPlaysAsRenderedAtNormalPitch() async throws {
        let normal = try await bedAfterAReply(atPitch: VoiceLoop.defaultSpeechPitch)
        let higher = try await bedAfterAReply(atPitch: VoiceLoop.speechPitches.upperBound)
        let lower = try await bedAfterAReply(atPitch: VoiceLoop.speechPitches.lowerBound)

        #expect(abs(zeroCrossingsPerSecond(on: normal) - 880) <= 880 / 20)
        #expect(abs(zeroCrossingsPerSecond(on: higher) - 1760) <= 1760 / 10)
        #expect(abs(zeroCrossingsPerSecond(on: lower) - 440) <= 440 / 10)
        // At normal pitch the shift is bypassed: the three sentences play as Kokoro rendered them.
        #expect(try pitchShift(in: normal.audio.engines.last).bypass)
        let expected = 3 * fakeSentenceFrames
        #expect(abs(normal.audio.playedFrames - expected) <= expected / 20)
    }

    @Test func aVoicePreviewWhileListeningIsSpokenByKokoro() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }

        loop.preview("Hello.")

        #expect(loop.state == .speaking)
        #expect(await eventually { loop.state == .listening(partial: "") })
        #expect(bed.kokoro.requests.map(\.text) == ["Hello."])
    }
}

// MARK: - Previews while the loop is off

/// A preview while voice mode is off plays on the preview player's engine of its own, which
/// is the test bed's offline audio too.
@MainActor
@Suite(.serialized, .oneVoiceLoopAtATime, .timeLimit(.minutes(1)))
struct KokoroPreviewTests {
    /// A loop that is off, with the Heart voice chosen and its model loaded.
    private func offLoopWithKokoro(on bed: VoiceTestBed) async -> VoiceLoop {
        let loop = bed.makeLoop()
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { loop.kokoroModelState == .ready })
        return loop
    }

    @Test func aPreviewWhileOffIsSpokenByKokoroOnItsOwnEngineAtTheChosenPitch() async throws {
        let bed = VoiceTestBed()
        let loop = await offLoopWithKokoro(on: bed)
        loop.speechPitch = VoiceLoop.speechPitches.upperBound

        loop.preview("Hello there.")

        #expect(loop.state == .off)
        #expect(bed.audio.engines.count == 1)
        let engine = try #require(bed.audio.engines.first)
        #expect(try pitchShift(in: engine).pitch == 1200)
        // Its engine stops once it has played.
        #expect(await eventually { !engine.isRunning })
        #expect(bed.kokoro.requests == [FakeKokoro.Request(text: "Hello there.", voice: "af_heart", speed: 1)])
        #expect(abs(zeroCrossingsPerSecond(on: bed) - 1760) <= 1760 / 10)
    }

    @Test func aPreviewWhileOffSaysThePronunciations() async throws {
        let bed = VoiceTestBed()
        let loop = await offLoopWithKokoro(on: bed)
        loop.pronunciations = [Pronunciation(word: "Heart", replacement: "Hart")]

        loop.preview("This is the Heart voice.")

        #expect(await eventually { bed.kokoro.requests.count == 1 })
        #expect(bed.kokoro.requests.map(\.text) == ["This is the Hart voice."])
        loop.stopPreview()
    }

    @Test func aPreviewWhileOffBeforeTheModelIsReadyIsSpokenByTheSystemVoice() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.loadBehavior = .waits
        let loop = bed.makeLoop()
        loop.voiceIdentifier = "kokoro.af_heart"

        loop.preview("Hi.")

        let engine = try #require(bed.audio.engines.first)
        #expect(await eventually { !engine.isRunning })
        #expect(bed.audio.playedFrames > 0)
        #expect(bed.kokoro.requests.isEmpty)
        bed.kokoro.finishLoading(succeeding: true)
    }

    @Test func aNewPreviewDropsTheSentenceKokoroIsStillRenderingForTheOneBefore() async throws {
        let bed = VoiceTestBed()
        let loop = await offLoopWithKokoro(on: bed)
        bed.kokoro.holdsSynthesis = true
        loop.preview("The first one here. The second one here.")
        #expect(await eventually { bed.kokoro.heldSyntheses == 1 })
        let first = try #require(bed.audio.engines.last)

        loop.preview("Next.")
        #expect(await eventually { bed.kokoro.heldSyntheses == 2 })
        bed.kokoro.holdsSynthesis = false
        bed.kokoro.releaseSyntheses()
        let second = try #require(bed.audio.engines.last)
        #expect(await eventually { !second.isRunning })
        try await settle()

        #expect(!first.isRunning)
        // Only "Next." played: the cut-off preview's late sentence went nowhere.
        #expect(bed.kokoro.requests.map(\.text) == ["The first one here.", "Next."])
        #expect(abs(bed.audio.playedFrames - fakeSentenceFrames) <= fakeSentenceFrames / 20)
    }

    @Test func startingVoiceModeDropsTheSentenceAPreviewIsStillRendering() async throws {
        let bed = VoiceTestBed()
        let loop = await offLoopWithKokoro(on: bed)
        loop.pauseThreshold = .milliseconds(50)
        bed.kokoro.holdsSynthesis = true
        loop.preview("The first one here. The second one here.")
        #expect(await eventually { bed.kokoro.heldSyntheses == 1 })

        try await loop.start()
        defer { loop.stop() }
        bed.kokoro.releaseSyntheses()
        try await settle()

        #expect(loop.state == .listening(partial: ""))
        #expect(bed.kokoro.requests.count == 1)
        #expect(bed.audio.playedFrames == 0)
    }

    @Test func aPreviewOfAWordWithPhonemesIsSpokenByKokoroWithThem() async throws {
        let bed = VoiceTestBed()
        let loop = await offLoopWithKokoro(on: bed)

        loop.preview(word: "Kokoro", phonemes: "kˈOkəɹO")
        let first = try #require(bed.audio.engines.last)
        #expect(await eventually { !first.isRunning })
        // Unsaved phonemes too, such as a suggestion being tried.
        loop.preview(word: "Kokoro", phonemes: "kəkˈɔɹO")
        let second = try #require(bed.audio.engines.last)
        #expect(await eventually { !second.isRunning })

        #expect(bed.kokoro.requests == [
            FakeKokoro.Request(
                text: placeholder(0, capital: true),
                voice: "af_heart",
                speed: 1,
                pronunciations: [placeholder(0): "kˈOkəɹO"]
            ),
            FakeKokoro.Request(
                text: placeholder(1, capital: true),
                voice: "af_heart",
                speed: 1,
                pronunciations: [placeholder(1): "kəkˈɔɹO"]
            ),
        ])
        #expect(bed.systemVoiceTexts.isEmpty)
    }

    @Test func aPreviewOfAWordWithPhonemesBeforeTheModelIsReadyIsTheWordAsWritten() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.loadBehavior = .waits
        let loop = bed.makeLoop()
        loop.voiceIdentifier = "kokoro.af_heart"

        loop.preview(word: "Kokoro", phonemes: "kˈOkəɹO")

        // The system voice is given the preview as it starts; it needn't be heard.
        loop.stopPreview()
        #expect(bed.systemVoiceTexts == ["Kokoro"])
        #expect(bed.kokoro.requests.isEmpty)
        bed.kokoro.finishLoading(succeeding: true)
    }

    @Test func aPreviewOfAnEmptyWordOrEmptyPhonemesSaysNothing() async throws {
        let bed = VoiceTestBed()
        let loop = await offLoopWithKokoro(on: bed)

        loop.preview(word: "", phonemes: "kˈOkəɹO")
        loop.preview(word: "Kokoro", phonemes: "")
        try await settle()

        #expect(bed.audio.engines.isEmpty)
        #expect(bed.kokoro.requests.isEmpty)
    }
}

// MARK: - Freeing the model

/// The model is freed from memory while no Kokoro voice is chosen. It stays downloaded, so
/// choosing a Kokoro voice again loads it without the network.
@MainActor
@Suite(.serialized, .oneVoiceLoopAtATime, .timeLimit(.minutes(1)))
struct KokoroReleaseTests {
    @Test func choosingASystemVoiceFreesTheModelAndAKokoroVoiceLoadsItAgain() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }
        let systemVoice = try #require(loop.voices.first { $0.engine == .system })

        loop.voiceIdentifier = systemVoice.id

        #expect(loop.kokoroModelState == .notLoaded)
        #expect(await eventually { bed.kokoro.unloads == 1 && !bed.kokoro.isLoaded })
        #expect(await framesPlayed(saying: "Hi.", by: loop, on: bed) > 0)
        #expect(bed.kokoro.requests.isEmpty)

        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { loop.kokoroModelState == .ready })
        #expect(bed.kokoro.loads == 2)
        _ = await framesPlayed(saying: "Hi.", by: loop, on: bed)
        #expect(bed.kokoro.requests.map(\.text) == ["Hi."])
    }

    @Test func aDownloadUnderWayWhenASystemVoiceIsChosenFinishesAndIsThenFreed() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.loadBehavior = .waits
        let loop = bed.makeLoop()
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { bed.kokoro.loads == 1 })

        loop.voiceIdentifier = nil
        // The download carries on.
        #expect(loop.kokoroModelState == .loading)
        bed.kokoro.finishLoading(succeeding: true)

        #expect(await eventually { loop.kokoroModelState == .notLoaded && bed.kokoro.unloads == 1 })
        #expect(!bed.kokoro.isLoaded)
    }

    @Test func aKokoroVoiceChosenAgainBeforeTheDownloadFinishesKeepsTheModel() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.loadBehavior = .waits
        let loop = bed.makeLoop()
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { bed.kokoro.loads == 1 })

        loop.voiceIdentifier = nil
        loop.voiceIdentifier = "kokoro.af_bella"
        bed.kokoro.finishLoading(succeeding: true)

        #expect(await eventually { loop.kokoroModelState == .ready })
        try await settle()
        #expect(bed.kokoro.loads == 1)
        #expect(bed.kokoro.unloads == 0)
        #expect(bed.kokoro.isLoaded)
    }

    @Test func aFailedLoadIsForgottenWhenASystemVoiceIsChosen() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.loadBehavior = .fails
        let loop = bed.makeLoop()
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { loop.kokoroModelState == .failed })

        loop.voiceIdentifier = nil

        // Settings shows no failure, and no retry, for a voice that isn't chosen.
        #expect(loop.kokoroModelState == .notLoaded)
        loop.loadKokoroModel()
        try await settle()
        #expect(bed.kokoro.loads == 1)
    }

    @Test func aDownloadThatFailsAfterASystemVoiceIsChosenOffersNoRetry() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.loadBehavior = .waits
        let loop = bed.makeLoop()
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { bed.kokoro.loads == 1 })

        loop.voiceIdentifier = nil
        bed.kokoro.finishLoading(succeeding: false)

        #expect(await eventually { bed.kokoro.loads == 1 && loop.kokoroModelState == .notLoaded })
        // Nothing to retry for while a system voice is chosen.
        loop.loadKokoroModel()
        try await settle()
        #expect(bed.kokoro.loads == 1)
        #expect(loop.kokoroModelState == .notLoaded)
    }

    @Test func aModelFreedMidReplyLeavesTheRestOfItToTheNewVoice() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }
        bed.kokoro.holdsSynthesis = true
        loop.speak("The first sentence here. The second sentence here.")
        #expect(await eventually { bed.kokoro.heldSyntheses == 1 })

        loop.voiceIdentifier = nil
        bed.kokoro.holdsSynthesis = false
        bed.kokoro.releaseSyntheses()

        #expect(await eventually { loop.state == .listening(partial: "") })
        // Kokoro's first sentence played, then the system voice said the second.
        #expect(bed.kokoro.requests.map(\.text) == ["The first sentence here."])
        #expect(bed.audio.playedFrames > fakeSentenceFrames + fakeSentenceFrames / 2)
    }
}

// MARK: - Choosing the model

@MainActor
@Suite(.serialized, .oneVoiceLoopAtATime, .timeLimit(.minutes(1)))
struct KokoroModelChoiceTests {
    @Test(arguments: [KokoroModelVariant.masked5s, .fluidAudio5s])
    func choosingAnotherVoiceLoadsItAndUsesTheSystemVoiceUntilReady(variant: KokoroModelVariant) async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        loop.kokoroModelVariant = variant
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { loop.kokoroModelState == .ready })

        bed.kokoro.loadBehavior = .waits
        loop.voiceIdentifier = "kokoro.af_bella"

        #expect(loop.kokoroModelState == .loading)
        #expect(await eventually { bed.kokoro.loads == 2 })
        #expect(bed.kokoro.loadedModels == [variant, variant])
        #expect(bed.kokoro.loadedVoices == ["af_heart", "af_bella"])
        #expect(await framesPlayed(saying: "Hi.", by: loop, on: bed) > 0)
        #expect(bed.kokoro.requests.isEmpty)

        bed.kokoro.finishLoading(succeeding: true)
        #expect(await eventually { loop.kokoroModelState == .ready })
        _ = await framesPlayed(saying: "Hi.", by: loop, on: bed)
        #expect(bed.kokoro.requests.map(\.voice) == ["af_bella"])
    }

    @Test func choosingAnotherSoniqoVoiceNeedsNoNewLoad() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }
        bed.kokoro.loadBehavior = .fails

        loop.voiceIdentifier = "kokoro.af_bella"

        // Still ready at once, so a preview or reply right after the pick is spoken by Kokoro
        // in the new voice, not by the system voice.
        #expect(loop.kokoroModelState == .ready)
        _ = await framesPlayed(saying: "Hi.", by: loop, on: bed)
        #expect(bed.kokoro.requests.map(\.voice) == ["af_bella"])
        try await settle()
        // Not even a call that would find the voice already loaded.
        #expect(bed.kokoro.loadCalls == 1)
        #expect(loop.kokoroModelState == .ready)
    }

    @Test func aSoniqoVoiceChosenWhileTheModelLoadsNeedsNoSecondLoad() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.loadBehavior = .waits
        let loop = bed.makeLoop()
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { bed.kokoro.loads == 1 })

        loop.voiceIdentifier = "kokoro.af_bella"
        bed.kokoro.finishLoading(succeeding: true)

        #expect(await eventually { loop.kokoroModelState == .ready })
        try await settle()
        // The load with the first voice counts for the second: no second call at all.
        #expect(bed.kokoro.loadCalls == 1)
        #expect(loop.kokoroModelState == .ready)
    }

    @Test(arguments: [true, false])
    func aVoiceChosenWhileAnotherLoadsIsLoadedOnceThatOneFinishes(succeeding: Bool) async throws {
        let bed = VoiceTestBed()
        bed.kokoro.loadBehavior = .waits
        let loop = bed.makeLoop()
        loop.kokoroModelVariant = .masked5s
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { bed.kokoro.loads == 1 })

        loop.voiceIdentifier = "kokoro.af_nicole"
        loop.voiceIdentifier = "kokoro.af_bella"
        try await settle()
        #expect(bed.kokoro.loads == 1)
        #expect(loop.kokoroModelState == .loading)
        bed.kokoro.finishLoading(succeeding: succeeding)

        #expect(await eventually { bed.kokoro.loads == 2 })
        #expect(loop.kokoroModelState == .loading)
        #expect(bed.kokoro.loadedVoices == ["af_heart", "af_bella"])
        bed.kokoro.finishLoading(succeeding: true)
        #expect(await eventually { loop.kokoroModelState == .ready })
        #expect(bed.kokoro.loadedModels == [.masked5s, .masked5s])
    }

    @Test func choosingAnotherVoiceAfterAFailureTriesIt() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.loadBehavior = .fails
        let loop = bed.makeLoop()
        loop.kokoroModelVariant = .masked5s
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { loop.kokoroModelState == .failed })

        bed.kokoro.loadBehavior = .succeeds
        loop.voiceIdentifier = "kokoro.af_bella"

        #expect(await eventually { loop.kokoroModelState == .ready })
        #expect(bed.kokoro.loadedVoices == ["af_heart", "af_bella"])
    }

    @Test func choosingASystemVoiceThenAKokoroVoiceLoadsTheChosenVoice() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        loop.kokoroModelVariant = .masked5s
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { loop.kokoroModelState == .ready })

        loop.voiceIdentifier = try #require(loop.voices.first { $0.engine == .system }).id
        loop.voiceIdentifier = "kokoro.af_bella"

        #expect(await eventually { loop.kokoroModelState == .ready })
        #expect(bed.kokoro.loadedModels == [.masked5s, .masked5s])
        #expect(bed.kokoro.loadedVoices == ["af_heart", "af_bella"])
        #expect(bed.kokoro.unloads == 1)
    }

    @Test func choosingTheOtherModelLoadsItInPlaceOfTheOneLoaded() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }
        #expect(loop.kokoroModelVariant == .soniqo5s)
        #expect(bed.kokoro.loadedModel == .soniqo5s)

        loop.kokoroModelVariant = .fluidAudio15s

        #expect(loop.kokoroModelState == .loading)
        #expect(await eventually { loop.kokoroModelState == .ready })
        #expect(bed.kokoro.loadedModels == [.soniqo5s, .fluidAudio15s])
        #expect(bed.kokoro.loadedModel == .fluidAudio15s)
        _ = await framesPlayed(saying: "Hi.", by: loop, on: bed)
        #expect(bed.kokoro.requests.map(\.text) == ["Hi."])

        // Choosing the model already chosen loads nothing.
        loop.kokoroModelVariant = .fluidAudio15s
        try await settle()
        #expect(bed.kokoro.loads == 2)
        #expect(loop.kokoroModelState == .ready)
    }

    @Test func untilTheNewModelIsReadyTheSystemVoiceSpeaks() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }
        bed.kokoro.loadBehavior = .waits

        loop.kokoroModelVariant = .fluidAudio15s
        #expect(await eventually { bed.kokoro.loads == 2 })

        #expect(await framesPlayed(saying: "Hi.", by: loop, on: bed) > 0)
        #expect(bed.kokoro.requests.isEmpty)
        bed.kokoro.finishLoading(succeeding: true)
        #expect(await eventually { loop.kokoroModelState == .ready })
        #expect(bed.kokoro.loadedModel == .fluidAudio15s)
    }

    @Test func aModelChosenWhileAnotherLoadsIsLoadedOnceThatOneFinishes() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.loadBehavior = .waits
        let loop = bed.makeLoop()
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { bed.kokoro.loads == 1 })

        loop.kokoroModelVariant = .fluidAudio15s
        // The download carries on.
        #expect(loop.kokoroModelState == .loading)
        bed.kokoro.finishLoading(succeeding: true)

        #expect(await eventually { bed.kokoro.loads == 2 })
        #expect(loop.kokoroModelState == .loading)
        bed.kokoro.finishLoading(succeeding: true)
        #expect(await eventually { loop.kokoroModelState == .ready })
        #expect(bed.kokoro.loadedModels == [.soniqo5s, .fluidAudio15s])
        #expect(bed.kokoro.loadedModel == .fluidAudio15s)
    }

    @Test func aModelChosenWhileAnotherFailsToLoadIsTriedInstead() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.loadBehavior = .waits
        let loop = bed.makeLoop()
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { bed.kokoro.loads == 1 })

        loop.kokoroModelVariant = .fluidAudio15s
        bed.kokoro.finishLoading(succeeding: false)

        // No failure shown: the model chosen now is loading.
        #expect(await eventually { bed.kokoro.loads == 2 })
        #expect(loop.kokoroModelState == .loading)
        bed.kokoro.finishLoading(succeeding: true)
        #expect(await eventually { loop.kokoroModelState == .ready })
        #expect(bed.kokoro.loadedModel == .fluidAudio15s)
    }

    @Test func choosingTheOtherModelAfterAFailureTriesIt() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.loadBehavior = .fails
        let loop = bed.makeLoop()
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { loop.kokoroModelState == .failed })

        bed.kokoro.loadBehavior = .succeeds
        loop.kokoroModelVariant = .fluidAudio15s

        #expect(await eventually { loop.kokoroModelState == .ready })
        #expect(bed.kokoro.loadedModels == [.soniqo5s, .fluidAudio15s])
    }

    @Test func withASystemVoiceChosenTheNextKokoroVoiceLoadsTheChosenModel() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()

        loop.kokoroModelVariant = .fluidAudio10s
        try await settle()
        #expect(bed.kokoro.loads == 0)
        #expect(loop.kokoroModelState == .notLoaded)

        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { loop.kokoroModelState == .ready })
        #expect(bed.kokoro.loadedModels == [.fluidAudio10s])
    }

    @Test func withNoModelChosenAKokoroVoiceLoadsNothingUntilAModelIsChosen() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        loop.kokoroModelVariant = nil

        loop.voiceIdentifier = "kokoro.af_heart"
        try await settle()
        #expect(bed.kokoro.loadCalls == 0)
        #expect(loop.kokoroModelState == .notLoaded)

        loop.kokoroModelVariant = .masked5s
        #expect(loop.kokoroModelState == .loading)
        #expect(await eventually { loop.kokoroModelState == .ready })
        #expect(bed.kokoro.loadedModels == [.masked5s])
    }

    @Test func choosingNoModelFreesTheLoadedOneAndTheSystemVoiceSpeaks() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }

        loop.kokoroModelVariant = nil

        #expect(loop.kokoroModelState == .notLoaded)
        #expect(await eventually { bed.kokoro.unloads == 1 && !bed.kokoro.isLoaded })
        #expect(await framesPlayed(saying: "Hi.", by: loop, on: bed) > 0)
        #expect(bed.kokoro.requests.isEmpty)
        // Freed, not deleted.
        #expect(bed.kokoro.isStored)
        #expect(bed.kokoro.removals == 0)
    }

    @Test func choosingNoModelWhileOneLoadsFreesItOnceItFinishes() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.loadBehavior = .waits
        let loop = bed.makeLoop()
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { bed.kokoro.loads == 1 })

        loop.kokoroModelVariant = nil
        // The download carries on.
        #expect(loop.kokoroModelState == .loading)
        bed.kokoro.finishLoading(succeeding: true)

        #expect(await eventually { loop.kokoroModelState == .notLoaded && bed.kokoro.unloads == 1 })
        try await settle()
        #expect(bed.kokoro.loads == 1)
        #expect(!bed.kokoro.isLoaded)
        #expect(bed.kokoro.isStored)
    }

    @Test func choosingNoModelWhileOneLoadsLeavesNothingToRetryIfItFails() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.loadBehavior = .waits
        let loop = bed.makeLoop()
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { bed.kokoro.loads == 1 })

        loop.kokoroModelVariant = nil
        bed.kokoro.finishLoading(succeeding: false)

        #expect(await eventually { loop.kokoroModelState == .notLoaded })
        try await settle()
        #expect(bed.kokoro.loadCalls == 1)
        #expect(loop.kokoroModelState == .notLoaded)
    }

    @Test func choosingNoModelAfterAFailureLeavesNothingToRetry() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.loadBehavior = .fails
        let loop = bed.makeLoop()
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { loop.kokoroModelState == .failed })

        loop.kokoroModelVariant = nil

        #expect(loop.kokoroModelState == .notLoaded)
        loop.loadKokoroModel()
        try await settle()
        #expect(bed.kokoro.loadCalls == 1)
        #expect(loop.kokoroModelState == .notLoaded)
    }
}

// MARK: - Deleting the model

private let hour: TimeInterval = 60 * 60
private let day: TimeInterval = 24 * hour

/// The stored model is deleted once no Kokoro voice has been chosen for a day, when the app
/// checks (at launch and on returning to the foreground). The bed's clock stands still until a
/// test moves it, and the bed keeps the record of when the last Kokoro voice was unchosen.
@MainActor
@Suite(.serialized, .oneVoiceLoopAtATime, .timeLimit(.minutes(1)))
struct KokoroRemovalTests {
    /// A loop whose model was loaded for the Heart voice, then freed for a system voice.
    private func loopAfterSwitchingToASystemVoice(on bed: VoiceTestBed) async throws -> VoiceLoop {
        let loop = bed.makeLoop()
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { loop.kokoroModelState == .ready })
        loop.voiceIdentifier = try #require(loop.voices.first { $0.engine == .system }).id
        #expect(await eventually { bed.kokoro.unloads == 1 })
        return loop
    }

    @Test func theModelIsDeletedADayAfterASystemVoiceWasChosenAndAKokoroVoiceDownloadsItAgain() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopAfterSwitchingToASystemVoice(on: bed)
        #expect(bed.kokoroUnchosenSince == bed.now)

        bed.now += day
        loop.removeUnusedKokoroModel()

        #expect(await eventually { !bed.kokoro.isStored })
        #expect(bed.kokoro.removals == 1)
        #expect(loop.kokoroModelState == .notLoaded)

        loop.voiceIdentifier = "kokoro.af_bella"
        #expect(await eventually { loop.kokoroModelState == .ready })
        #expect(bed.kokoro.loads == 2)
        #expect(bed.kokoro.isStored)
    }

    @Test func theModelIsKeptUntilTheDayIsUp() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopAfterSwitchingToASystemVoice(on: bed)

        bed.now += day - 1
        loop.removeUnusedKokoroModel()
        try await settle()

        #expect(bed.kokoro.removals == 0)
        #expect(bed.kokoro.isStored)
    }

    @Test func theModelIsKeptWhileAKokoroVoiceIsChosenWhateverTheRecordSays() async throws {
        let bed = VoiceTestBed()
        // From a launch long ago, when a system voice was chosen.
        bed.kokoro.isStored = true
        bed.kokoroUnchosenSince = bed.now - 2 * day
        let loop = bed.makeLoop()
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { loop.kokoroModelState == .ready })
        #expect(bed.kokoroUnchosenSince == nil)

        bed.now += 2 * day
        loop.removeUnusedKokoroModel()
        // Switching between Kokoro voices changes nothing.
        loop.voiceIdentifier = "kokoro.af_bella"
        bed.now += 2 * day
        loop.removeUnusedKokoroModel()
        try await settle()

        #expect(bed.kokoro.removals == 0)
        #expect(bed.kokoro.isStored)
        #expect(bed.kokoroUnchosenSince == nil)
        #expect(bed.kokoro.loads == 1)
        #expect(loop.kokoroModelState == .ready)
    }

    @Test func choosingAKokoroVoiceAgainBeforeTheDayIsUpStartsTheDayOver() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopAfterSwitchingToASystemVoice(on: bed)
        let systemVoice = loop.voiceIdentifier

        bed.now += 23 * hour
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(bed.kokoroUnchosenSince == nil)
        #expect(await eventually { loop.kokoroModelState == .ready })
        loop.voiceIdentifier = systemVoice
        // A day after the first system voice, but two hours after the second.
        bed.now += 2 * hour
        loop.removeUnusedKokoroModel()
        try await settle()
        #expect(bed.kokoro.removals == 0)
        #expect(bed.kokoro.isStored)

        bed.now += 22 * hour
        loop.removeUnusedKokoroModel()
        #expect(await eventually { !bed.kokoro.isStored })
    }

    @Test func choosingAKokoroVoiceWhileADeletionWaitsItsTurnCancelsIt() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopAfterSwitchingToASystemVoice(on: bed)
        bed.now += day

        // In the same turn of the main actor, so the deletion hasn't reached the engine yet.
        loop.removeUnusedKokoroModel()
        loop.voiceIdentifier = "kokoro.af_heart"

        #expect(await eventually { loop.kokoroModelState == .ready })
        try await settle()
        #expect(bed.kokoro.removals == 0)
        #expect(bed.kokoro.isStored)
    }

    @Test func switchingBetweenSystemVoicesDoesNotPutOffTheDeletion() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopAfterSwitchingToASystemVoice(on: bed)

        bed.now += 12 * hour
        // The default voice, another system voice.
        loop.voiceIdentifier = nil
        bed.now += 12 * hour
        loop.removeUnusedKokoroModel()

        #expect(await eventually { !bed.kokoro.isStored })
    }

    @Test func withNoRecordTheDayStartsAtTheCheckInsteadOfDeletingAtOnce() async throws {
        let bed = VoiceTestBed()
        // Downloaded by a version that kept no record. The default voice is chosen.
        bed.kokoro.isStored = true
        let loop = bed.makeLoop()

        loop.removeUnusedKokoroModel()
        try await settle()
        #expect(bed.kokoro.removals == 0)
        #expect(bed.kokoro.isStored)
        #expect(bed.kokoroUnchosenSince == bed.now)

        bed.now += day
        loop.removeUnusedKokoroModel()
        #expect(await eventually { !bed.kokoro.isStored })
    }

    @Test func aModelStillDownloadingIsNotDeleted() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.loadBehavior = .waits
        let loop = bed.makeLoop()
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { bed.kokoro.loads == 1 })
        // Unchosen while it downloads; the download carries on.
        loop.voiceIdentifier = nil
        bed.now += day

        loop.removeUnusedKokoroModel()
        #expect(loop.kokoroModelState == .loading)
        bed.kokoro.finishLoading(succeeding: true)

        #expect(await eventually { loop.kokoroModelState == .notLoaded && bed.kokoro.unloads == 1 })
        try await settle()
        #expect(bed.kokoro.removals == 0)
        #expect(bed.kokoro.isStored)
    }

    @Test func deletingTheModelsWithAKokoroVoiceChosenDownloadsTheChosenOneAgain() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        loop.kokoroModelVariant = .masked5s
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { loop.kokoroModelState == .ready })

        loop.deleteKokoroModels()

        #expect(await eventually { bed.kokoro.removals == 1 && loop.kokoroModelState == .ready })
        #expect(bed.kokoro.loadedModels == [.masked5s, .masked5s])
        #expect(bed.kokoro.isLoaded)
        // Deleting isn't a day going unused: nothing about the record changes.
        #expect(bed.kokoroUnchosenSince == nil)
    }

    @Test func onceTheModelsAreBeingDeletedAReplyUsesTheSystemVoice() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }

        loop.deleteKokoroModels()

        // The engine frees the model as the deletion starts, so it no longer counts as ready.
        #expect(loop.kokoroModelState != .ready)
        #expect(await framesPlayed(saying: "Hi.", by: loop, on: bed) > 0)
        #expect(bed.kokoro.requests.isEmpty)
        // Then the chosen model downloads again.
        #expect(await eventually { bed.kokoro.removals == 1 && loop.kokoroModelState == .ready })
    }

    @Test func deletingTheModelsWithASystemVoiceChosenDownloadsNothing() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopAfterSwitchingToASystemVoice(on: bed)
        #expect(bed.kokoro.isStored)

        loop.deleteKokoroModels()

        #expect(await eventually { bed.kokoro.removals == 1 })
        try await settle()
        #expect(!bed.kokoro.isStored)
        #expect(bed.kokoro.loads == 1)
        #expect(loop.kokoroModelState == .notLoaded)
    }

    @Test func deletingTheModelsWhileOneLoadsWaitsForItThenDownloadsAgain() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.loadBehavior = .waits
        let loop = bed.makeLoop()
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { bed.kokoro.loads == 1 })

        loop.deleteKokoroModels()
        try await settle()
        #expect(bed.kokoro.removals == 0)
        bed.kokoro.finishLoading(succeeding: true)

        // Deleted once the load finished, then loaded again.
        #expect(await eventually { bed.kokoro.removals == 1 && bed.kokoro.loads == 2 })
        bed.kokoro.finishLoading(succeeding: true)
        #expect(await eventually { loop.kokoroModelState == .ready })
    }

    @Test func deletingTheModelsWithNoModelChosenDownloadsNothing() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { loop.kokoroModelState == .ready })

        loop.kokoroModelVariant = nil
        loop.deleteKokoroModels()

        #expect(await eventually { bed.kokoro.removals == 1 })
        try await settle()
        #expect(!bed.kokoro.isStored)
        #expect(bed.kokoro.loads == 1)
        #expect(loop.kokoroModelState == .notLoaded)
    }
}

// MARK: - Cancelling

/// Speaking stops while Kokoro is still rendering a sentence. Nothing more is rendered, and the
/// sentence that was rendering is dropped when it arrives.
@MainActor
@Suite(.serialized, .oneVoiceLoopAtATime, .timeLimit(.minutes(1)))
struct KokoroCancellingTests {
    /// Starts saying two sentences, and waits until the first is rendering.
    private func startSpeaking(by loop: VoiceLoop, on bed: VoiceTestBed) async {
        bed.kokoro.holdsSynthesis = true
        loop.speak("The first sentence here. The second sentence here.")
        #expect(loop.state == .speaking)
        #expect(await eventually { bed.kokoro.heldSyntheses == 1 })
    }

    @Test func stopSpeakingDropsTheSentenceBeingRenderedEvenOnceTheNextReplyHasStarted() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }
        await startSpeaking(by: loop, on: bed)

        loop.stopSpeaking()
        loop.speak("Next.")
        #expect(await eventually { bed.kokoro.heldSyntheses == 2 })
        bed.kokoro.holdsSynthesis = false
        bed.kokoro.releaseSyntheses()

        #expect(await eventually { loop.state == .listening(partial: "") })
        // "Next." reaches the speaker a render pass after it counts as played, and the late
        // sentence, had it gone anywhere, would play in the passes after: many passes, counted
        // rather than timed, since a busy machine can take far longer than usual to render them.
        try await settle()
        #expect(await renderPassesGoBy(20, on: bed))
        // Only "Next." played: the cut-off reply's late sentence went nowhere.
        #expect(bed.kokoro.requests.map(\.text) == ["The first sentence here.", "Next."])
        #expect(abs(bed.audio.playedFrames - fakeSentenceFrames) <= fakeSentenceFrames / 20)
    }

    @Test func talkingOverTheReplyDropsTheSentenceBeingRendered() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }
        await startSpeaking(by: loop, on: bed)

        bed.recognizer.hear("Wait.", over: later, isFinal: true)
        #expect(await eventually { loop.state == .listening(partial: "Wait.") })
        bed.kokoro.releaseSyntheses()
        try await settle()

        #expect(bed.kokoro.requests.count == 1)
        #expect(bed.audio.playedFrames == 0)
    }

    @Test func stoppingTheLoopDropsTheSentenceBeingRendered() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        await startSpeaking(by: loop, on: bed)

        loop.stop()
        bed.kokoro.releaseSyntheses()
        try await settle()

        #expect(loop.state == .off)
        #expect(bed.kokoro.requests.count == 1)
        #expect(bed.audio.playedFrames == 0)
    }
}

// MARK: - Pieces

@Suite struct KokoroSentenceTests {
    @Test func aMessageIsSplitIntoItsSentences() {
        #expect(KokoroText.sentences(in: "Hello there. How are you? I'm fine!") == ["Hello there.", "How are you?", "I'm fine!"])
    }

    @Test func eachLineIsASentenceEvenWithoutPunctuation() {
        #expect(KokoroText.sentences(in: "Summary\nfirst item\nsecond item. Done") == ["Summary", "first item", "second item.", "Done"])
    }

    @Test func numbersAndTitlesStayInTheirSentence() {
        #expect(KokoroText.sentences(in: "Mr. Smith paid 3.50 for it. Then he left.") == ["Mr. Smith paid 3.50 for it.", "Then he left."])
    }

    @Test func blankLinesAndSpacesAreDropped() {
        #expect(KokoroText.sentences(in: "  One.  \n\n  Two.  ") == ["One.", "Two."])
        #expect(KokoroText.sentences(in: " \n ").isEmpty)
    }
}

@Suite struct KokoroSpeedTests {
    @MainActor
    @Test func theNormalRateIsNormalSpeedAndTheEndsHalveAndDoubleIt() {
        #expect(KokoroSpeed.speed(forRate: VoiceLoop.defaultSpeechRate) == 1)
        #expect(KokoroSpeed.speed(forRate: VoiceLoop.speechRates.lowerBound) == 0.5)
        #expect(KokoroSpeed.speed(forRate: VoiceLoop.speechRates.upperBound) == 2)
    }

    @Test func fasterRatesAreFasterAndRatesOutsideTheRangeAreClamped() {
        let rates = stride(from: Float(0), through: 1, by: 0.05)
        let speeds = rates.map { KokoroSpeed.speed(forRate: $0) }
        #expect(speeds == speeds.sorted())
        #expect(Set(speeds).count == speeds.count)
        #expect(KokoroSpeed.speed(forRate: -1) == 0.5)
        #expect(KokoroSpeed.speed(forRate: 3) == 2)
    }
}

@Suite struct KokoroAudioTests {
    @Test func samplesBecome24kHzMonoBuffersOfATenthOfASecondAtMost() throws {
        let samples = (0..<5_000).map { Float($0) / 5_000 }

        let buffers = KokoroAudio.buffers(samples)

        #expect(buffers.map(\.frameLength) == [2_400, 2_400, 200])
        #expect(buffers.allSatisfy { $0.format.sampleRate == 24_000 && $0.format.channelCount == 1 })
        let joined = try buffers.flatMap { buffer in
            Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
        }
        #expect(joined == samples)
    }

    @Test func noSamplesMakeNoBuffers() {
        #expect(KokoroAudio.buffers([]).isEmpty)
    }
}

// MARK: - The voice list

@Suite struct KokoroVoiceListTests {
    @Test func americanEnglishGetsTheAmericanVoicesBestFirstWithoutTheNoveltyVoice() {
        let voices = KokoroCatalog.voices(forLanguage: "en-US")

        #expect(voices.count == 19)
        #expect(voices.prefix(3).map(\.id) == ["kokoro.af_heart", "kokoro.af_bella", "kokoro.af_nicole"])
        #expect(voices.first?.name == "Heart")
        #expect(voices.allSatisfy { $0.engine == .kokoro && $0.id.hasPrefix("kokoro.a") })
        #expect(!voices.contains { $0.id == "kokoro.am_santa" })
    }

    @Test func britishEnglishGetsTheBritishVoicesBestFirst() {
        let voices = KokoroCatalog.voices(forLanguage: "en-GB")

        #expect(voices.count == 8)
        #expect(voices.first?.id == "kokoro.bf_emma")
        #expect(voices.allSatisfy { $0.engine == .kokoro && $0.id.hasPrefix("kokoro.b") })
    }

    @Test func otherLanguagesGetNoKokoroVoices() {
        for language in ["en-AU", "en-IN", "fr-FR", "ja-JP"] {
            #expect(KokoroCatalog.voices(forLanguage: language).isEmpty)
        }
    }

    @Test func noKokoroVoiceIDIsASystemVoiceID() {
        let ids = (KokoroCatalog.voices(forLanguage: "en-US") + KokoroCatalog.voices(forLanguage: "en-GB")).map(\.id)
        #expect(Set(ids).count == ids.count)
        for id in ids {
            #expect(AVSpeechSynthesisVoice(identifier: id) == nil)
        }
    }

    @Test func kokoroVoiceIDsAreFoundInEitherLanguageAndOthersAreNot() {
        #expect(KokoroCatalog.kokoroVoice(forOptionID: "kokoro.af_heart") == "af_heart")
        #expect(KokoroCatalog.kokoroVoice(forOptionID: "kokoro.bm_george") == "bm_george")
        #expect(KokoroCatalog.kokoroVoice(forOptionID: "kokoro.am_santa") == nil)
        #expect(KokoroCatalog.kokoroVoice(forOptionID: "af_heart") == nil)
        #expect(KokoroCatalog.kokoroVoice(forOptionID: "com.apple.voice.compact.en-US.Samantha") == nil)
    }

    @MainActor
    @Test func theVoiceListEndsWithTheCurrentLanguagesKokoroVoices() {
        let kokoro = VoiceLoop.availableVoices().filter { $0.engine == .kokoro }
        #expect(kokoro == KokoroCatalog.voices(forLanguage: AVSpeechSynthesisVoice.currentLanguageCode()))
    }
}

/// A Kokoro voice chosen in one language, with the system then in another (as after the user
/// changes the system language and the app relaunches).
@MainActor
@Suite(.serialized, .oneVoiceLoopAtATime, .timeLimit(.minutes(1)))
struct KokoroLanguageTests {
    @Test func aKokoroVoiceNotOfferedInTheLanguageIsSetAsideUntilItIsOfferedAgain() async throws {
        let bed = VoiceTestBed()
        bed.languageCode = "en-GB"
        let loop = bed.makeLoop()
        loop.pauseThreshold = .milliseconds(50)

        loop.voiceIdentifier = "kokoro.af_heart"
        try await loop.start()

        // British English offers only British Kokoro voices: the best system voice speaks, and
        // no model is loaded for it.
        #expect(loop.voices.contains { $0.id == "kokoro.bf_emma" })
        #expect(!loop.voices.contains { $0.id == "kokoro.af_heart" })
        #expect(loop.voiceIdentifier == "kokoro.af_heart")
        #expect(loop.chosenVoice == nil)
        #expect(await framesPlayed(saying: "Hi.", by: loop, on: bed) > 0)
        #expect(bed.kokoro.loads == 0)
        #expect(loop.kokoroModelState == .notLoaded)
        #expect(bed.kokoro.requests.isEmpty)

        // Back in American English, the next start of voice mode picks the voice up again.
        loop.stop()
        bed.languageCode = "en-US"
        try await loop.start()
        defer { loop.stop() }
        #expect(loop.chosenVoice?.id == "kokoro.af_heart")
        #expect(await eventually { loop.kokoroModelState == .ready })
        _ = await framesPlayed(saying: "Hi.", by: loop, on: bed)
        #expect(bed.kokoro.requests == [FakeKokoro.Request(text: "Hi.", voice: "af_heart", speed: 1)])
    }

    @Test func noKokoroVoiceIsOfferedOrUsedInALanguageKokoroDoesNotSpeak() async throws {
        let bed = VoiceTestBed()
        bed.languageCode = "fr-FR"
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        loop.voiceIdentifier = "kokoro.af_heart"

        #expect(!loop.voices.contains { $0.engine == .kokoro })
        #expect(loop.chosenVoice == nil)
        #expect(await framesPlayed(saying: "Bonjour.", by: loop, on: bed) > 0)
        #expect(bed.kokoro.loads == 0)
        #expect(bed.kokoro.requests.isEmpty)
    }
}

// MARK: - The real engine

@Suite struct LiveKokoroTests {
    @Test func aStoredMarkerNeedsTheChosenVoiceBeforeLoadingOffline() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "winston-kokoro-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appending(path: "Kokoro-82M-Masked")
        try FileManager.default.createDirectory(at: folder.appending(path: "voices"), withIntermediateDirectories: true)
        let marker = directory.appending(path: "Kokoro-82M-Masked.kokoro_masked_5s_fp16.downloaded")
        try Data().write(to: marker)
        let engine = LiveKokoro(directory: directory)

        #expect(await engine.canLoadOffline(.masked5s, voice: "af_bella") == false)
        try Data().write(to: folder.appending(path: "voices/af_heart.json"))
        #expect(await engine.canLoadOffline(.masked5s, voice: "af_bella") == false)
        #expect(await engine.canLoadOffline(.masked5s, voice: "af_heart"))
        try Data().write(to: folder.appending(path: "voices/af_bella.json"))
        #expect(await engine.canLoadOffline(.masked5s, voice: "af_bella"))
        try FileManager.default.removeItem(at: marker)
        #expect(await engine.canLoadOffline(.masked5s, voice: "af_bella") == false)
    }

    @Test func aRequestCancelledBeforeItsTurnNeverReachesTheModel() async throws {
        // Nothing is loaded or stored here: a request that reached the model would fail with
        // `notLoaded` instead.
        let engine = LiveKokoro(directory: FileManager.default.temporaryDirectory.appending(path: "winston-unused-\(UUID())"))

        let result = await Task {
            // Stopped while it waits for an earlier request to render.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.synthesize("Hello.", voice: "af_heart", speed: 1, pronunciations: [:])
        }.result

        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test func removingTheStoredModelsDeletesEachFolderAndMarkerAndNothingElse() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "winston-kokoro-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        // As finished downloads of every model leave them: soniqo's model's folder, the
        // masked models' folder and FluidAudio's folder, each shared by three models, and each
        // model's marker. Plus a file of someone else's.
        for name in ["Kokoro-82M-CoreML", "Kokoro-82M-Masked", "Kokoro-82M-15s"] {
            let folder = directory.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder.appending(path: "voices"), withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: folder.appending(path: "voices/af_heart.json"))
        }
        let markers = [
            "Kokoro-82M-CoreML",
            "Kokoro-82M-Masked.kokoro_masked_5s_fp16",
            "Kokoro-82M-Masked.kokoro_masked_10s_fp16",
            "Kokoro-82M-Masked.kokoro_masked_15s_fp16",
            "Kokoro-82M-15s",
            "Kokoro-82M-15s.kokoro_21_10s",
            "Kokoro-82M-15s.kokoro_21_5s",
        ]
        for marker in markers {
            try Data().write(to: directory.appending(path: "\(marker).downloaded"))
        }
        try Data().write(to: directory.appending(path: "other"))
        let engine = LiveKokoro(directory: directory)

        #expect(try await engine.removeStoredModel())

        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(left == ["other"])
        // Nothing more to remove.
        #expect(try await engine.removeStoredModel() == false)
    }

    @Test func theDictionaryWordsAreTheOnesKokoroFindsInLowercase() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "winston-kokoro-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // As KokoroTTS has them: a phoneme string, or one for each part of speech.
        try Data(#"{"nasa": "nˈæsə", "NATO": "nˈAɾO", "ID": {"DEFAULT": "ˈɪd", "NOUN": null}, "dB": "dˌibˈi"}"#.utf8)
            .write(to: folder.appending(path: "us_gold.json"))
        try Data(#"{"isn't": "ˈɪzᵊnt"}"#.utf8).write(to: folder.appending(path: "us_silver.json"))

        // Not "db": KokoroTTS looks "DB" up as "db", and has no such key.
        #expect(LiveKokoro.dictionaryWords(in: folder) == ["nasa", "nato", "id", "isn't"])
        // Without one of the dictionaries, there are no words at all.
        try FileManager.default.removeItem(at: folder.appending(path: "us_silver.json"))
        #expect(LiveKokoro.dictionaryWords(in: folder).isEmpty)
    }

    @Test func withoutALoadedModelThereAreNoDictionaryWords() async throws {
        let engine = LiveKokoro(directory: FileManager.default.temporaryDirectory.appending(path: "winston-unused-\(UUID())"))

        #expect(await engine.dictionaryWords().isEmpty)
    }

    @Test func thePhonemeSymbolsAreTheVocabularysOneCharacterKeysFlatOrUnderVocab() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "winston-kokoro-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "vocab_index.json")

        // As KokoroTTS reads it: under "vocab", with other keys beside it.
        try Data(#"{"vocab": {"ɹ": 123, "A": 24, "ˈ": 156, " ": 16, "ab": 7}, "metadata": {"version": 1}}"#.utf8).write(to: file)
        // KokoroTTS looks up each character on its own, so "ab" is never found.
        #expect(LiveKokoro.phonemeSymbols(in: folder) == ["ɹ", "A", "ˈ", " "])
        // Or at the top level.
        try Data(#"{"ʤ": 82, "ɡ": 92}"#.utf8).write(to: file)
        #expect(LiveKokoro.phonemeSymbols(in: folder) == ["ʤ", "ɡ"])
        // Anything else, or no file, gives none.
        try Data(#"["ɹ", "A"]"#.utf8).write(to: file)
        #expect(LiveKokoro.phonemeSymbols(in: folder).isEmpty)
        try FileManager.default.removeItem(at: file)
        #expect(LiveKokoro.phonemeSymbols(in: folder).isEmpty)
    }

    @Test func withoutALoadedModelThereAreNoPhonemeSymbols() async throws {
        let engine = LiveKokoro(directory: FileManager.default.temporaryDirectory.appending(path: "winston-unused-\(UUID())"))

        #expect(await engine.phonemeSymbols().isEmpty)
    }
}

/// The symbols suggested phonemes are checked against.
@MainActor
@Suite(.serialized, .oneVoiceLoopAtATime, .timeLimit(.minutes(1)))
struct KokoroPhonemeSymbolTests {
    @Test func withoutAReadyModelTheyAreMisakisUSSymbols() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.symbols = ["x"]
        let loop = bed.makeLoop()

        #expect(loop.kokoroPhonemeSymbols == MisakiPhonemes.usSymbols)
        // Still loading.
        bed.kokoro.loadBehavior = .waits
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { bed.kokoro.loads == 1 })
        #expect(loop.kokoroPhonemeSymbols == MisakiPhonemes.usSymbols)
        bed.kokoro.finishLoading(succeeding: true)
        #expect(await eventually { loop.kokoroModelState == .ready })
        #expect(loop.kokoroPhonemeSymbols == ["x"])
        // A system voice frees the model.
        loop.voiceIdentifier = nil
        #expect(loop.kokoroPhonemeSymbols == MisakiPhonemes.usSymbols)
    }

    @Test func theyAreReadOnceAsTheModelLoads() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.symbols = ["ɹ", "x"]
        let loop = bed.makeLoop()
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { loop.kokoroModelState == .ready })
        #expect(loop.kokoroPhonemeSymbols == ["ɹ", "x"])

        // A change to the engine's vocabulary shows only once the model loads again.
        bed.kokoro.symbols = ["y"]
        #expect(loop.kokoroPhonemeSymbols == ["ɹ", "x"])
        loop.voiceIdentifier = nil
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { loop.kokoroModelState == .ready })
        #expect(loop.kokoroPhonemeSymbols == ["y"])
    }

    @Test func aVocabularyThatCantBeReadGivesMisakisUSSymbols() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()

        // The fake's vocabulary is empty, as the engine's is when its file can't be read.
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually { loop.kokoroModelState == .ready })

        #expect(loop.kokoroPhonemeSymbols == MisakiPhonemes.usSymbols)
    }

    @Test func theyAreObservable() async throws {
        let bed = VoiceTestBed()
        bed.kokoro.symbols = ["x"]
        let loop = bed.makeLoop()
        let changed = Mutex(false)
        withObservationTracking {
            _ = loop.kokoroPhonemeSymbols
        } onChange: {
            changed.withLock { $0 = true }
        }

        loop.voiceIdentifier = "kokoro.af_heart"

        #expect(await eventually { loop.kokoroPhonemeSymbols == ["x"] })
        #expect(changed.withLock { $0 })
    }
}

// MARK: - The real model

/// Where `KokoroRealModelTests` looks for the downloaded model: `WINSTON_KOKORO_MODEL_DIR`, or
/// `.build/kokoro-model` in the package.
private let realModelDirectory: URL = {
    if let path = ProcessInfo.processInfo.environment["WINSTON_KOKORO_MODEL_DIR"] {
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return package.appending(path: ".build/kokoro-model", directoryHint: .isDirectory)
}()

/// Whether the default model, soniqo's 5 s one, has been downloaded (335 MB).
private let realModelIsDownloaded = FileManager.default.fileExists(
    atPath: realModelDirectory.appending(path: "Kokoro-82M-CoreML.downloaded").path
)

/// Whether FluidAudio's 15 s model has been downloaded too (335 MB, with one voice).
private let realFifteenSecondModelIsDownloaded = FileManager.default.fileExists(
    atPath: realModelDirectory.appending(path: "Kokoro-82M-15s.downloaded").path
)

/// Whether FluidAudio's 10 s and 5 s models have been downloaded too (325 MB each), into the 15 s
/// model's folder.
private let realFluidAudioModelsAreDownloaded = ["Kokoro-82M-15s.kokoro_21_10s", "Kokoro-82M-15s.kokoro_21_5s"].allSatisfy {
    FileManager.default.fileExists(atPath: realModelDirectory.appending(path: "\($0).downloaded").path)
}

/// Passes everything to the real engine, and counts the samples it rendered that aren't silent.
private final class RecordingKokoro: KokoroEngine {
    private let engine: any KokoroEngine
    private let renderedSamples = Mutex(0)

    init(_ engine: any KokoroEngine) {
        self.engine = engine
    }

    var audibleSamples: Int { renderedSamples.withLock { $0 } }

    func load(
        _ variant: KokoroModelVariant,
        voice: String,
        downloadProgress: @escaping @Sendable (Double) -> Void,
        stageChanged: @escaping @Sendable (KokoroLoadStage) -> Void
    ) async throws {
        try await engine.load(variant, voice: voice, downloadProgress: downloadProgress, stageChanged: stageChanged)
    }

    func unload() async {
        await engine.unload()
    }

    func removeStoredModel() async throws -> Bool {
        try await engine.removeStoredModel()
    }

    func dictionaryWords() async -> Set<String> {
        await engine.dictionaryWords()
    }

    func phonemeSymbols() async -> Set<Character> {
        await engine.phonemeSymbols()
    }

    func synthesize(_ text: String, voice: String, speed: Float, pronunciations: [String: String]) async throws -> [Float] {
        let samples = try await engine.synthesize(text, voice: voice, speed: speed, pronunciations: pronunciations)
        renderedSamples.withLock { $0 += samples.count { abs($0) >= 0.001 } }
        return samples
    }
}

/// The real KokoroTTS model, with no network: skipped unless the model has already been
/// downloaded into `realModelDirectory`. The tests that switch to FluidAudio's models also need
/// those downloaded.
@MainActor
@Suite(
    .serialized,
    .oneVoiceLoopAtATime,
    .enabled(if: realModelIsDownloaded, "the Kokoro model hasn't been downloaded"),
    .timeLimit(.minutes(2))
)
struct KokoroRealModelTests {
    @Test func theRealModelSpeaksThroughTheVoiceLoop() async throws {
        let bed = VoiceTestBed()
        let kokoro = RecordingKokoro(LiveKokoro(directory: realModelDirectory))
        var environment = bed.environment
        environment.kokoro = kokoro
        let loop = VoiceLoop(environment: environment)
        loop.pauseThreshold = .milliseconds(50)
        try await loop.start()
        defer { loop.stop() }

        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually(timeout: .seconds(60)) { loop.kokoroModelState == .ready })
        loop.speak("Hello there. This is the Kokoro voice, speaking through the voice loop.")
        #expect(loop.state == .speaking)
        #expect(await eventually(timeout: .seconds(60)) { loop.state == .listening(partial: "") })

        // Kokoro's audio, and nothing else, reached the speaker, resampled to 48 kHz.
        let rendered = kokoro.audibleSamples
        #expect(rendered > 24_000)
        #expect(abs(bed.audio.playedFrames - 2 * rendered) <= 2 * rendered / 10)

        // Freed for a system voice, then loaded again from the stored download.
        loop.voiceIdentifier = nil
        #expect(loop.kokoroModelState == .notLoaded)
        loop.voiceIdentifier = "kokoro.af_bella"
        #expect(await eventually(timeout: .seconds(60)) { loop.kokoroModelState == .ready })
        loop.speak("And hello again at 10:30, 3.5% up on 2025's $1,200.")
        #expect(await eventually(timeout: .seconds(60)) { loop.state == .listening(partial: "") })
        #expect(kokoro.audibleSamples > rendered)
    }

    @Test(.enabled(if: realFifteenSecondModelIsDownloaded, "FluidAudio's 15 s model hasn't been downloaded"))
    func choosingTheOtherRealModelSpeaksWithItInstead() async throws {
        let bed = VoiceTestBed()
        let kokoro = RecordingKokoro(LiveKokoro(directory: realModelDirectory))
        var environment = bed.environment
        environment.kokoro = kokoro
        let loop = VoiceLoop(environment: environment)
        loop.pauseThreshold = .milliseconds(50)
        try await loop.start()
        defer { loop.stop() }
        loop.voiceIdentifier = "kokoro.af_heart"
        #expect(await eventually(timeout: .seconds(60)) { loop.kokoroModelState == .ready })

        loop.kokoroModelVariant = .fluidAudio15s

        #expect(loop.kokoroModelState == .loading)
        #expect(await eventually(timeout: .seconds(60)) { loop.kokoroModelState == .ready })
        loop.speak("Hello from FluidAudio's model.")
        #expect(await eventually(timeout: .seconds(60)) { loop.state == .listening(partial: "") })
        #expect(kokoro.audibleSamples > 24_000)
    }

    @Test(.enabled(if: realFluidAudioModelsAreDownloaded, "FluidAudio's 10 s and 5 s models haven't been downloaded"))
    func fluidAudiosOtherModelsSpeakFromTheSharedFolder() async throws {
        let bed = VoiceTestBed()
        let kokoro = RecordingKokoro(LiveKokoro(directory: realModelDirectory))
        var environment = bed.environment
        environment.kokoro = kokoro
        let loop = VoiceLoop(environment: environment)
        loop.pauseThreshold = .milliseconds(50)
        try await loop.start()
        defer { loop.stop() }
        loop.voiceIdentifier = "kokoro.af_heart"

        for variant in [KokoroModelVariant.fluidAudio10s, .fluidAudio5s] {
            let before = kokoro.audibleSamples
            loop.kokoroModelVariant = variant
            #expect(await eventually(timeout: .seconds(60)) { loop.kokoroModelState == .ready })
            loop.speak("Hello from \(variant.name).")
            #expect(await eventually(timeout: .seconds(60)) { loop.state == .listening(partial: "") })
            #expect(kokoro.audibleSamples - before > 24_000)
        }
    }
}

// MARK: - Load and render times

/// The models `KokoroLoadTimingTests` times: raw values separated by commas, such as
/// `masked5s,masked15s`, from `WINSTON_KOKORO_TIMING`, or else from `timing-models.txt` in
/// `realModelDirectory`.
private let timedModels: [KokoroModelVariant] = {
    let file = realModelDirectory.appending(path: "timing-models.txt", directoryHint: .notDirectory)
    let list = ProcessInfo.processInfo.environment["WINSTON_KOKORO_TIMING"]
        ?? (try? String(contentsOf: file, encoding: .utf8))
        ?? ""
    return list
        .split { $0 == "," || $0.isWhitespace }
        .compactMap { KokoroModelVariant(rawValue: String($0)) }
}()

/// How long the real models take to load and to render, for the models `timedModels` names, in
/// `realModelDirectory` (each downloads first if it isn't stored). A first load can compile the
/// model for the Neural Engine, which for the masked models (when they were allowed it) took over
/// an hour on a Mac, hence the long limit. Prints one `KOKORO TIMING` line per model. Run it on
/// its own: it is slow and uses a lot of memory.
@Suite(
    .serialized,
    .enabled(if: !timedModels.isEmpty, "neither WINSTON_KOKORO_TIMING nor timing-models.txt names a model"),
    .timeLimit(.minutes(180))
)
struct KokoroLoadTimingTests {
    @Test func eachModelsFirstLoadSecondLoadAndRenderTimes() async throws {
        let sentence = "I checked the build server this morning, and both jobs finished without errors."
        let clock = ContinuousClock()
        func milliseconds(since start: ContinuousClock.Instant) -> Int {
            Int(start.duration(to: clock.now) / .milliseconds(1))
        }

        for variant in timedModels {
            let engine = LiveKokoro(directory: realModelDirectory)

            var start = clock.now
            try await engine.load(variant, voice: "af_heart") { _ in } stageChanged: { _ in }
            let firstLoad = milliseconds(since: start)
            start = clock.now
            let firstAudio = try await engine.synthesize(sentence, voice: "af_heart", speed: 1, pronunciations: [:])
            let firstRender = milliseconds(since: start)

            // Loaded again, as at the next launch: anything compiled the first time is cached.
            await engine.unload()
            start = clock.now
            try await engine.load(variant, voice: "af_heart") { _ in } stageChanged: { _ in }
            let secondLoad = milliseconds(since: start)
            start = clock.now
            let audio = try await engine.synthesize(sentence, voice: "af_heart", speed: 1, pronunciations: [:])
            let render = milliseconds(since: start)
            let fast = try await engine.synthesize(sentence, voice: "af_heart", speed: 2, pronunciations: [:])

            print(
                "KOKORO TIMING model=\(variant.rawValue) firstLoadMs=\(firstLoad) firstRenderMs=\(firstRender)",
                "secondLoadMs=\(secondLoad) renderMs=\(render) samples=\(audio.count) fastSamples=\(fast.count)"
            )
            #expect(firstAudio.count > 24_000)
            #expect(audio.count > 24_000)
            await engine.unload()
        }
    }
}
