import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import VoiceLoop
import VoiceLoopTestSupport

// Kokoro voices. The session tests run the real `VoiceLoop` on a `VoiceTestBed`, whose
// `FakeKokoro` renders each sentence as 0.2 s of steady sound, so `bed.audio.playedFrames` tells
// Kokoro's audio from the system voice's.

/// What the speaker plays for one sentence from `FakeKokoro`, at 48 kHz.
private let fakeSentenceFrames = Int(FakeKokoro.secondsPerSentence * 48_000)

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

/// Says `text` and waits until the loop has finished. Returns how much sound came out.
@MainActor
private func framesPlayed(saying text: String, by loop: VoiceLoop, on bed: VoiceTestBed) async -> Int {
    let before = bed.audio.playedFrames
    loop.speak(text)
    #expect(loop.state == .speaking)
    #expect(await eventually { loop.state == .listening(partial: "") })
    return bed.audio.playedFrames - before
}

// MARK: - Speaking

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
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

    @Test func choosingAKokoroVoiceLoadsTheModelOnceAndASystemVoiceDoesNot() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        let systemVoice = try #require(VoiceLoop.availableVoices().first { $0.engine == .system })

        loop.voiceIdentifier = systemVoice.id
        // Not a voice in the catalog, so the system voice speaks.
        loop.voiceIdentifier = "kokoro.no_such_voice"
        try await settle()
        #expect(bed.kokoro.loads == 0)
        #expect(loop.kokoroModelState == .notLoaded)

        loop.voiceIdentifier = "kokoro.bf_emma"
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

// MARK: - Freeing the model

/// The model is freed from memory while no Kokoro voice is chosen. It stays downloaded, so
/// choosing a Kokoro voice again loads it without the network.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct KokoroReleaseTests {
    @Test func choosingASystemVoiceFreesTheModelAndAKokoroVoiceLoadsItAgain() async throws {
        let bed = VoiceTestBed()
        let loop = try await loopSpeakingWithKokoro(on: bed)
        defer { loop.stop() }
        let systemVoice = try #require(VoiceLoop.availableVoices().first { $0.engine == .system })

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
        loop.voiceIdentifier = "kokoro.bf_emma"
        bed.kokoro.finishLoading(succeeding: true)

        #expect(await eventually { loop.kokoroModelState == .ready })
        try await settle()
        #expect(bed.kokoro.loads == 1)
        #expect(bed.kokoro.unloads == 0)
        #expect(bed.kokoro.isLoaded)
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

// MARK: - Cancelling

/// Speaking stops while Kokoro is still rendering a sentence. Nothing more is rendered, and the
/// sentence that was rendering is dropped when it arrives.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
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
        try await settle()
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

private let realModelIsDownloaded = FileManager.default.fileExists(
    atPath: realModelDirectory.appending(path: "Kokoro-82M-CoreML.downloaded").path
)

/// Passes everything to the real engine, and counts the samples it rendered that aren't silent.
private final class RecordingKokoro: KokoroEngine {
    private let engine: any KokoroEngine
    private let renderedSamples = Mutex(0)

    init(_ engine: any KokoroEngine) {
        self.engine = engine
    }

    var audibleSamples: Int { renderedSamples.withLock { $0 } }

    func load(downloadProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await engine.load(downloadProgress: downloadProgress)
    }

    func unload() async {
        await engine.unload()
    }

    func synthesize(_ text: String, voice: String, speed: Float) async throws -> [Float] {
        let samples = try await engine.synthesize(text, voice: voice, speed: speed)
        renderedSamples.withLock { $0 += samples.count { abs($0) >= 0.001 } }
        return samples
    }
}

/// The real KokoroTTS model, with no network: skipped unless the model has already been
/// downloaded (335 MB) into `realModelDirectory`.
@MainActor
@Suite(
    .serialized,
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

        // Kokoro's audio, and nothing else, reached the speaker, resampled to 48 kHz. The fade-in
        // quiets a little of its start.
        let rendered = kokoro.audibleSamples
        #expect(rendered > 24_000)
        #expect(abs(bed.audio.playedFrames - 2 * rendered) <= 2 * rendered / 10)

        // Freed for a system voice, then loaded again from the stored download.
        loop.voiceIdentifier = nil
        #expect(loop.kokoroModelState == .notLoaded)
        loop.voiceIdentifier = "kokoro.bf_emma"
        #expect(await eventually(timeout: .seconds(60)) { loop.kokoroModelState == .ready })
        loop.speak("And hello again.")
        #expect(await eventually(timeout: .seconds(60)) { loop.state == .listening(partial: "") })
        #expect(kokoro.audibleSamples > rendered)
    }
}
