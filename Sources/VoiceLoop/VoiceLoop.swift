import AVFoundation
import Foundation
import Logging
import LogSupport
import Observation
import Speech
#if os(iOS)
import UIKit
#endif

/// Hands-free voice loop: listens, detects the end of an utterance, speaks replies,
/// and stops speaking when the user talks over it (barge-in).
///
/// One `AVAudioEngine` does everything. Its input node has voice processing on, so the app's
/// own speech is removed from the microphone signal, and feeds a `SpeechAnalyzer` running
/// `SpeechTranscriber`. If voice processing can't start, the engine runs without it and the
/// microphone is ignored while a reply plays (half-duplex: only `stopSpeaking()`
/// interrupts). Speech is rendered with `AVSpeechSynthesizer.write(_:toBufferCallback:)`, or by
/// Kokoro for a Kokoro voice, and played on an `AVAudioPlayerNode` in the same engine, through
/// a pitch shift (see `SpeechOutput`). Sound cues (`SoundCue`) play on a second player node
/// there, not pitch-shifted: taps when listening starts and stops, and whatever `play(_:)` is
/// asked for.
@MainActor
@Observable
public final class VoiceLoop {
    nonisolated static let log = Logger(label: "voice.loop")

    public enum State: Sendable, Equatable {
        case off
        /// Listening; `partial` is the live transcript of the current utterance (may be empty).
        case listening(partial: String)
        /// Speaking a reply. With echo cancellation, listening continues so the user can
        /// interrupt by talking; without it, only `stopSpeaking()` interrupts.
        case speaking
    }

    /// `.off` means voice mode is stopped: before the first successful `start()`, after
    /// `stop()`, and after an unrecoverable failure (a failed `start()`, a transcriber failure,
    /// an audio interruption iOS doesn't let it resume from, or the engine stopping itself more
    /// than 3 times in 10 seconds). While the engine is rebuilt after an audio route change,
    /// and during an audio interruption, it stays `.listening(partial: "")`. iOS doesn't promise to report an interruption's end, so the
    /// loop also retries when the app next comes to the foreground. That retry may run while
    /// the interruption is still active; if it fails, `state` shows `.off`, but the loop still
    /// resumes if iOS later reports the interruption's end.
    public private(set) var state: State = .off
    /// How long the transcript must stay unchanged before an utterance is finished.
    public var pauseThreshold: Duration = .milliseconds(1200)
    /// The `VoiceOption.id` to speak with; nil picks the best installed system voice. Choosing a
    /// Kokoro voice downloads and loads its model if needed (see `kokoroModelState`), and until
    /// it is ready, the best system voice speaks instead. Choosing any other voice frees the
    /// loaded model's memory; it stays downloaded for a day (see `removeUnusedKokoroModel()`).
    public var voiceIdentifier: String? {
        didSet {
            guard voiceIdentifier != oldValue else { return }
            if isKokoroVoiceChosen {
                kokoroModel.load()
            } else {
                kokoroModel.release()
            }
        }
    }
    /// The Kokoro voices' model. It downloads and loads when a Kokoro voice is chosen, and when
    /// voice mode starts with one chosen.
    public var kokoroModelState: KokoroModelState {
        kokoroModel.state
    }
    /// Which Kokoro model speaks the Kokoro voices. Choosing another while a Kokoro voice is
    /// chosen loads it in place of the one loaded, downloading it the first time, and until it is
    /// ready the best system voice speaks.
    public var kokoroModelVariant: KokoroModelVariant {
        get { kokoroModel.variant }
        set { kokoroModel.variant = newValue }
    }
    /// The Kokoro model until another is chosen.
    public static let defaultKokoroModelVariant = KokoroModelVariant.fluidAudio15s
    /// `AVSpeechUtterance.rate` to speak at, within `speechRates`. The scale isn't linear:
    /// `defaultSpeechRate` (the middle) is normal speed. Applies from the next message spoken.
    public var speechRate: Float = VoiceLoop.defaultSpeechRate
    /// The rates `speechRate` can take.
    public static let speechRates: ClosedRange<Float> = AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate
    /// Normal speaking speed.
    public static let defaultSpeechRate: Float = AVSpeechUtteranceDefaultSpeechRate
    /// How high to speak, as a multiplier of the voice's own pitch, within `speechPitches`: 1 is
    /// the voice's normal pitch, 2 an octave up. The audio is shifted after synthesis, so it
    /// works the same for every voice. Applies from the next message spoken.
    public var speechPitch: Float = VoiceLoop.defaultSpeechPitch
    /// The multipliers `speechPitch` can take.
    public static let speechPitches: ClosedRange<Float> = 0.5...2.0
    /// The voice's normal pitch.
    public static let defaultSpeechPitch: Float = 1.0
    /// While speaking, transcripts with fewer words than this are ignored instead of
    /// interrupting. Raise it if the app's own voice leaks through echo cancellation. Without
    /// echo cancellation (if it couldn't start), speech never interrupts a reply.
    public var bargeInMinimumWords = 1
    /// Whether voice mode may pause or turn down other apps' audio, such as music. When false,
    /// the iOS audio session mixes with other audio instead of interrupting it, and voice
    /// processing ducks other audio as little as it can (it has no setting for not at all).
    /// Changing this while the loop is running rebuilds the engine to apply it.
    public var pausesOtherAudio = true {
        didSet {
            guard pausesOtherAudio != oldValue, pipeline != nil else { return }
            restart(resettingAudioSession: true)
        }
    }
    /// Whether `play(_:)` and the start and stop of listening make a sound. Most tests turn it
    /// off, since they measure what was spoken by how much sound came out.
    @ObservationIgnored package var playsSoundCues = true

    /// One element per finished utterance. Iterate it from one long-lived task (for example
    /// the app model): it has a single consumer, and cancelling that iteration ends the
    /// stream for good.
    @ObservationIgnored public let utterances: AsyncStream<Utterance>
    @ObservationIgnored private let utteranceContinuation: AsyncStream<Utterance>.Continuation

    /// The running engine and analyzer. Nil while off, while starting, and during a rebuild
    /// or an interruption (when `state` is still `.listening`).
    @ObservationIgnored private var pipeline: Pipeline?
    /// The pipeline playing the stop cue after `stop()`: it has stopped listening, and its engine
    /// runs only until the cue has played. Nil otherwise.
    @ObservationIgnored private var closingPipeline: Pipeline?
    /// True while `start()` is running, so a second call doesn't start a second pipeline.
    @ObservationIgnored private var isStarting = false
    /// Bumped by every teardown (stop, rebuild, interruption), so a `start()` that one of
    /// them overtook gives up.
    @ObservationIgnored private var runID = 0
    /// Set when an interruption stopped the loop, so it restarts when the interruption ends
    /// (or, if iOS never says so, when the app becomes active). Cleared by `tearDown(.stop)`,
    /// except that a failed foreground retry sets it again.
    @ObservationIgnored private var resumeAfterInterruption = false
    /// When the engine stopped on its own, within the last `engineStopWindow`. Cleared when
    /// voice mode stops and when a settings change rebuilds the engine, so each start counts
    /// afresh (on the iPhone, every new engine has stopped once right after starting).
    @ObservationIgnored private var recentEngineStops: [ContinuousClock.Instant] = []

    @ObservationIgnored private var transcript = Transcript()
    @ObservationIgnored private var pauseDetector = PauseDetector(pauseThreshold: .milliseconds(1200))

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    /// Renders voice previews when the loop isn't running, for `previewPlayer`. See `preview(_:)`.
    @ObservationIgnored private let previewSynthesizer = AVSpeechSynthesizer()
    /// Plays voice previews when the loop isn't running.
    @ObservationIgnored private let previewPlayer: PreviewPlayer
    /// The synthesizer's delegate (held strongly; `delegate` is weak). Tells the playback
    /// when synthesis has finished.
    @ObservationIgnored private let synthesisObserver = SynthesisObserver()
    /// The same, for `previewSynthesizer`.
    @ObservationIgnored private let previewSynthesisObserver = SynthesisObserver()
    /// The Kokoro voices' model and its state.
    @ObservationIgnored private let kokoroModel: KokoroModel
    /// Renders the message being spoken with Kokoro, a sentence at a time. Nil when the message
    /// is spoken by the system synthesizer, or when not speaking.
    @ObservationIgnored private var kokoroSynthesis: Task<Void, Never>?
    /// The same, for a preview played while the loop is off.
    @ObservationIgnored private var previewKokoroSynthesis: Task<Void, Never>?
    @ObservationIgnored private var speechQueue: [String] = []
    /// The message being rendered and played; nil when not speaking.
    @ObservationIgnored private var currentSpeech: SpeechPlayback?
    /// Set when a result was ignored as too short while speaking (possibly the reply's own
    /// echo). When speaking ends, all audio fed so far is consumed if this is set,
    /// `bargeInMinimumWords` is above 1, or echo cancellation is off (echo is expected then,
    /// and a short reply's echo may only arrive after playback). That also covers the echo of the last words, whose results
    /// lag behind the audio. With echo cancellation at the default of 1 nothing is consumed,
    /// so words spoken right as a reply ends are kept; without it everything fed so far, plus
    /// a short margin, is consumed.
    @ObservationIgnored private var ignoredWhileSpeaking = false
    /// Results ignored while the current reply plays, for the logs.
    @ObservationIgnored private var ignoredResultsThisReply = 0
    /// Cues scheduled on the current pipeline that haven't finished playing, oldest first, with
    /// the ID their completion reports. If the engine stops itself, they play again from the
    /// start once it is running again.
    @ObservationIgnored private var unfinishedCues: [(id: Int, cue: SoundCue)] = []
    /// The ID of the last cue scheduled. IDs only grow, so a late completion for a cue that was
    /// cut off can't mark a newer one finished.
    @ObservationIgnored private var lastCueID = 0
    /// Set once voice processing fails to start, so later starts go straight to an engine
    /// without it (a failed attempt can block the main thread for seconds).
    @ObservationIgnored private var skipVoiceProcessing = false
    /// The permission prompts, the speech recognizer and the audio hardware.
    @ObservationIgnored private let environment: VoiceEnvironment
    /// The system voices of `voices` and the language they were listed for. Listing them blocks
    /// the main thread on the speech service for tens of milliseconds, and a voice picker reads
    /// `chosenVoice` once for every voice it lists, so they are listed once and kept. Emptied
    /// when the system's voices change (a voice installed or removed).
    @ObservationIgnored private var systemVoiceCache: (language: String, voices: [VoiceOption])?

    public convenience init() {
        self.init(environment: .live)
    }

    /// Tests pass a scripted recognizer, an audio engine that renders offline, and a fake Kokoro.
    package init(environment: VoiceEnvironment) {
        self.environment = environment
        previewPlayer = PreviewPlayer(environment: environment)
        kokoroModel = KokoroModel(environment: environment)
        (utterances, utteranceContinuation) = AsyncStream.makeStream(of: Utterance.self)
        synthesizer.delegate = synthesisObserver
        previewSynthesizer.delegate = previewSynthesisObserver
        observeSystem()
    }

    // MARK: - Public API

    /// Starts listening. Asks for microphone and speech permission on first use. With a Kokoro
    /// voice chosen, also loads its model, or tries again if that failed.
    ///
    /// Throws a `VoiceLoopError` when permission is missing or the speech model can't be
    /// installed, and passes audio engine errors through. Does nothing if already running.
    public func start() async throws {
        if pipeline == nil, !isStarting {
            loadKokoroModelIfChosen()
        }
        try await start(isForegroundRetry: false)
    }

    /// `isForegroundRetry` marks the retry after an interruption iOS never reported ending.
    /// If it fails, the interruption may still be live, so a later end still resumes the loop.
    private func start(isForegroundRetry: Bool) async throws {
        guard pipeline == nil, !isStarting else { return }
        // A preview playing outside the engine would be heard as speech once listening starts.
        stopPreviewPlayer()
        isStarting = true
        defer {
            isStarting = false
            // speak() queues while starting; if stop() came meanwhile, those replies are stale.
            // They are kept while a resume is still pending.
            if state == .off && !resumeAfterInterruption {
                speechQueue.removeAll()
            }
        }
        let run = runID
        do {
            try await startPipeline(run: run)
        } catch {
            // A start that stop() or an interruption overtook leaves the state to them.
            if run == runID {
                let queued = speechQueue
                tearDown(.stop)
                if isForegroundRetry {
                    // Replies keep queueing for the resume on a later end of the interruption.
                    resumeAfterInterruption = true
                    speechQueue = queued
                }
            }
            throw error
        }
    }

    /// The body of `start()`. Returns quietly if `runID` moves on while it waits.
    private func startPipeline(run: Int) async throws {
        try await environment.requestPermissions()
        let recognizer = try await environment.makeRecognizer()
        guard run == runID else { return }

        var newPipeline: Pipeline?
        // When `recognizer.start(inputs:)` was called and returned, for the timeline log.
        var recognizerStart = (called: UInt64(0), returned: UInt64(0))
        do {
            let pipeline = try makeRunningPipeline(analyzerFormat: recognizer.audioFormat, session: run)
            newPipeline = pipeline
            // Microphone buffers queue in `pipeline.inputs` until the recognizer starts reading.
            recognizerStart.called = TimelineClock.now()
            try await recognizer.start(inputs: pipeline.inputs)
            recognizerStart.returned = TimelineClock.now()
        } catch {
            newPipeline?.tearDown()
            await recognizer.cancel()
            Self.deactivateAudioSession()
            throw error
        }
        guard let pipeline = newPipeline, run == runID else {
            // stop() or an interruption came while the recognizer was starting.
            newPipeline?.tearDown()
            await recognizer.cancel()
            Self.deactivateAudioSession()
            return
        }

        pipeline.recognizer = recognizer
        self.pipeline = pipeline
        resumeAfterInterruption = false
        state = .listening(partial: "")
        // Also after a rebuild (a route change or an interruption), which has no "stopped" before it.
        Self.log.notice(
            "voice mode started",
            pipeline.formatContext.merging(["echoCancellation": "\(pipeline.hasVoiceProcessing)"]) { $1 }
        )
        pipeline.timeline.started(
            echoCancellation: pipeline.hasVoiceProcessing,
            fastResults: recognizer.reportsFastResults,
            tapFramesRequested: Pipeline.tapBufferSize,
            analyzerRate: recognizer.audioFormat.sampleRate
        )
        pipeline.timeline.recognizerStarted(called: recognizerStart.called, returned: recognizerStart.returned)

        let configurationChanges = NotificationCenter.default.notifications(
            named: .AVAudioEngineConfigurationChange,
            object: pipeline.engine
        )
        pipeline.tasks = [
            Task { [weak self] in
                await self?.listen(to: recognizer, in: pipeline)
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    self?.checkForPause()
                }
            },
            Task { [weak self, weak pipeline] in
                // The engine stops itself when the audio hardware changes, for example when
                // AirPods connect. Start it again so listening carries on.
                for await _ in configurationChanges {
                    guard let self, let pipeline, self.pipeline === pipeline else { return }
                    if !pipeline.engine.isRunning {
                        self.engineStopped(pipeline, source: "configurationChange")
                    }
                }
            },
        ]
        // The engine started before the analyzer, while nothing watched for configuration
        // changes; if one stopped it in that window, start it again now. A rebuild's new start
        // runs in a Task, after this start has finished and cleared `isStarting`.
        if !pipeline.engine.isRunning {
            engineStopped(pipeline, source: "startCheck")
        }
        // Adam can talk now, also after a rebuild or an interruption. Does nothing if the engine
        // is being rebuilt; the rebuild's start plays it.
        play(.listeningStarted)
        // Replies carried over a rebuild, or queued while starting. Does nothing if the engine
        // is being rebuilt.
        speakNextIfIdle()
    }

    /// Activates the iOS session and builds and starts the engine with voice processing (echo
    /// cancellation), or without it if voice processing can't start. Without echo cancellation
    /// the loop is half-duplex: replies can't be interrupted by voice.
    private func makeRunningPipeline(analyzerFormat: AVAudioFormat, session: Int) throws -> Pipeline {
        // Only one engine runs at a time, and this start owns the session from here on.
        endClosingPipeline()
        let pausingOtherAudio = pausesOtherAudio
        func started(voiceProcessing: Bool) throws -> Pipeline {
            try startedPipeline(
                analyzerFormat: analyzerFormat,
                voiceProcessing: voiceProcessing,
                ducksOtherAudio: pausingOtherAudio,
                session: session
            )
        }
        if !skipVoiceProcessing {
            // Outside the fallback below: a session that can't activate (a call holds it) is
            // not a voice processing failure.
            try Self.activateAudioSession(voiceProcessing: true, pausingOtherAudio: pausingOtherAudio)
            do {
                return try started(voiceProcessing: true)
            } catch {
                Self.log.warning("voice processing failed to start; trying without echo cancellation", error.logContext())
                try Self.activateAudioSession(voiceProcessing: false, pausingOtherAudio: pausingOtherAudio)
                let pipeline = try started(voiceProcessing: false)
                // Only voice processing failed, and a failed attempt can take seconds, so don't
                // try it again in this session. A start that fails either way (a route change
                // or call mid-start) leaves it on for next time.
                skipVoiceProcessing = true
                return pipeline
            }
        }
        try Self.activateAudioSession(voiceProcessing: false, pausingOtherAudio: pausingOtherAudio)
        return try started(voiceProcessing: false)
    }

    private func startedPipeline(
        analyzerFormat: AVAudioFormat,
        voiceProcessing: Bool,
        ducksOtherAudio: Bool,
        session: Int
    ) throws -> Pipeline {
        let pipeline = try Pipeline(
            analyzerFormat: analyzerFormat,
            voiceProcessing: voiceProcessing,
            ducksOtherAudio: ducksOtherAudio,
            session: session,
            environment: environment
        )
        do {
            try pipeline.engine.start()
        } catch {
            pipeline.tearDown()
            throw error
        }
        return pipeline
    }

    /// Stops listening and speaking. `state` is `.off` at once; the stop cue plays out on the
    /// engine for a moment after.
    public func stop() {
        tearDown(.stop)
    }

    /// Drops the utterance in progress without sending it.
    public func discardCurrentUtterance() {
        pipeline?.timeline.utteranceDiscarded(words: transcript.wordCount)
        transcript.discard()
        pauseDetector.reset()
        updateListeningState()
        speakNextIfIdle()
    }

    /// Queues `text` to be spoken after anything already queued. Strips markdown/code first.
    ///
    /// Ignored while the loop is off, except that replies still queue while a resume after an
    /// interruption is pending (a failed foreground retry shows `.off`). Also queued while it is
    /// starting or rebuilding. A message waits while an utterance is in progress, so the reply
    /// doesn't start over the user and get cut off by barge-in.
    public func speak(_ text: String) {
        guard state != .off || isStarting || resumeAfterInterruption else { return }
        let spoken = SpokenText.speakable(text)
        guard !spoken.isEmpty else { return }
        speechQueue.append(spoken)
        speakNextIfIdle()
    }

    /// Stops speaking and clears the queue.
    public func stopSpeaking() {
        speechQueue.removeAll()
        silence(consumingEcho: true, reason: "stopped")
    }

    /// Says `text` right away in the current voice, speed and pitch, for trying them in settings or
    /// hearing a message again, cutting off an earlier preview. Strips markdown/code first, as
    /// `speak(_:)` does. While the loop is running it also stops any reply being spoken and
    /// drops queued ones, and it plays through the loop's engine, so echo cancellation (or
    /// half-duplex) keeps it out of the transcript. Otherwise it plays straight to the speaker
    /// on an engine of its own. Like a reply, it uses the system voice for a Kokoro voice whose
    /// model isn't ready.
    public func preview(_ text: String) {
        stopPreviewPlayer()
        // Starting or rebuilding counts as running: speak() queues for the engine then, and
        // a preview played outside it would reach the microphone and be sent as speech.
        if state != .off || isStarting {
            stopSpeaking()
            speak(text)
            return
        }
        let text = SpokenText.speakable(text)
        guard !text.isEmpty else { return }
        let playback: SpeechPlayback
        do {
            playback = try previewPlayer.play(pitch: speechPitch)
        } catch {
            Self.log.error("voice preview failed to start", error.logContext())
            return
        }
        if let voice = readyKokoroVoice() {
            previewKokoroSynthesis = synthesizeWithKokoro(text, voice: voice, into: playback) { [self] rest in
                previewWithSystemVoice(rest, into: playback)
            }
        } else {
            previewWithSystemVoice(text, into: playback)
        }
    }

    private func previewWithSystemVoice(_ text: String, into playback: SpeechPlayback) {
        let utterance = makeUtterance(text)
        previewSynthesisObserver.track(utterance, playback: playback)
        previewSynthesizer.write(utterance) { @Sendable buffer in
            playback.receive(buffer)
        }
    }

    /// Cuts off a preview as a new `preview(_:)` would, for when there's nothing new to say: one
    /// playing on its own engine while the loop is off, or, while the loop is running, what it
    /// is saying (dropping the queue, as `stopSpeaking()` does).
    public func stopPreview() {
        stopPreviewPlayer()
        if state != .off || isStarting {
            stopSpeaking()
        }
    }

    /// Stops a preview played while the loop was off. Stopping the player cancels its playback,
    /// so a sentence Kokoro is still rendering is dropped.
    private func stopPreviewPlayer() {
        previewKokoroSynthesis?.cancel()
        previewKokoroSynthesis = nil
        previewSynthesizer.stopSpeaking(at: .immediate)
        previewPlayer.stop()
    }

    /// Plays `cue` through the loop's engine, mixed with any reply being spoken, so echo
    /// cancellation keeps it out of what is heard. It doesn't change `state`. Plays only while
    /// the loop is listening or speaking: does nothing while off, starting, or rebuilding the
    /// engine. A cue still playing finishes first.
    public func play(_ cue: SoundCue) {
        guard playsSoundCues, let pipeline, pipeline.engine.isRunning else { return }
        lastCueID += 1
        let id = lastCueID
        unfinishedCues.append((id, cue))
        pipeline.play(cue) { [weak self] in
            Task { @MainActor in self?.cueFinished(id) }
        }
    }

    /// The voices for `language` (the current one by default), for a settings picker: the
    /// installed system voices, then the Kokoro voices (for American and British English only),
    /// best first. System voices are ordered by quality, and within a quality the system's
    /// default voice comes first, then by name. Novelty voices are left out.
    public static func availableVoices(language: String = AVSpeechSynthesisVoice.currentLanguageCode()) -> [VoiceOption] {
        systemVoices(language: language) + KokoroCatalog.voices(forLanguage: language)
    }

    /// `availableVoices()`, the voices on offer: the ones settings lists and the loop speaks with.
    /// The system voices are listed once per language and kept (see `systemVoiceCache`), and
    /// listed again when the system's voices change.
    public var voices: [VoiceOption] {
        access(keyPath: \.voices)
        let language = environment.languageCode()
        return cachedSystemVoices(language: language) + KokoroCatalog.voices(forLanguage: language)
    }

    /// The voice `voiceIdentifier` picks, if it is one of `voices`. Nil otherwise, and then the
    /// best system voice speaks: a voice chosen in another language or region (say, an American
    /// Kokoro voice once the system is in British English) is set aside, not forgotten, and is
    /// used again when it is on offer again.
    public var chosenVoice: VoiceOption? {
        guard let voiceIdentifier else { return nil }
        return voices.first { $0.id == voiceIdentifier }
    }

    /// With a Kokoro voice chosen, downloads and loads its model if it isn't ready or on its way:
    /// a retry after `kokoroModelState` shows `.failed`.
    public func loadKokoroModel() {
        loadKokoroModelIfChosen()
    }

    /// Deletes the Kokoro voices' stored models (both, if both have been used) if no Kokoro voice
    /// has been chosen for a day. Choosing one again downloads the chosen model again. Without a
    /// record of when the last one was unchosen (a model downloaded by an earlier version), the
    /// day starts now. Does nothing while a Kokoro voice is chosen or a model is loading. For the
    /// app to call at launch, once it has set the saved `voiceIdentifier`, and when it returns to
    /// the foreground.
    public func removeUnusedKokoroModel() {
        kokoroModel.removeIfUnused()
    }

    /// The system voices of `voices`, from `systemVoiceCache` if it holds `language`'s.
    private func cachedSystemVoices(language: String) -> [VoiceOption] {
        if let systemVoiceCache, systemVoiceCache.language == language {
            return systemVoiceCache.voices
        }
        let voices = environment.systemVoices(language)
        systemVoiceCache = (language, voices)
        return voices
    }

    /// The system voices of `availableVoices(language:)`.
    package static func systemVoices(language: String) -> [VoiceOption] {
        let defaultID = AVSpeechSynthesisVoice(language: language)?.identifier
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .map { VoiceOption(id: $0.identifier, name: $0.name, quality: VoiceOption.Quality($0.quality)) }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
                if (lhs.id == defaultID) != (rhs.id == defaultID) { return lhs.id == defaultID }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    // MARK: - Listening

    /// Feeds the recognizer's results into the transcript until the pipeline is torn down.
    private func listen(to recognizer: any Recognizer, in pipeline: Pipeline) async {
        do {
            for try await piece in recognizer.results {
                // Results can still arrive after a teardown; they belong to the old session.
                guard self.pipeline === pipeline else { return }
                handle(piece)
            }
        } catch {
            // Falls through: an error ends the results just like the stream finishing.
            if self.pipeline === pipeline {
                Self.log.error("transcriber results failed", error.logContext())
            } else {
                // A teardown cancelled this pipeline's analyzer, which can end its results with an error.
                Self.log.debug("transcriber results ended after teardown", error.logContext())
            }
        }
        // The results ended while this pipeline is still running, so nothing more can be heard.
        if self.pipeline === pipeline {
            tearDown(.stop)
        }
    }

    private func handle(_ piece: TranscriptPiece) {
        var candidate = transcript
        guard candidate.apply(piece) else { return }
        if currentSpeech != nil {
            // Without echo cancellation the microphone hears the reply itself, so nothing
            // spoken interrupts it (the app's stop button still does).
            let echoCancelled = pipeline?.hasVoiceProcessing ?? false
            guard echoCancelled, candidate.wordCount >= max(1, bargeInMinimumWords) else {
                pipeline?.timeline.resultIgnored(
                    reason: echoCancelled ? "tooFewWords" : "noEchoCancellation",
                    words: candidate.wordCount
                )
                ignoredWhileSpeaking = true
                ignoredResultsThisReply += 1
                return
            }
            logResult(piece, applied: candidate)
            // Barge-in: speech over the reply stops it and becomes the next utterance. Results
            // ignored so far may be this utterance's first words, so no audio is consumed.
            Self.log.notice("speech interrupted a reply", ["words": candidate.wordCount])
            pipeline?.timeline.bargeInDecided(words: candidate.wordCount)
            speechQueue.removeAll()
            silence(consumingEcho: false, reason: "bargeIn")
        } else {
            logResult(piece, applied: candidate)
        }
        transcript = candidate
        pauseDetector.update(text: transcript.text, at: .now)
        updateListeningState()
        // An empty or revoked result can end the utterance a held reply was waiting on.
        speakNextIfIdle()
    }

    /// Logs a result on the timeline as the transcript is about to become `candidate`.
    private func logResult(_ piece: TranscriptPiece, applied candidate: Transcript) {
        pipeline?.timeline.result(
            piece,
            words: candidate.wordCount,
            isFirst: transcript.isEmpty && !candidate.isEmpty,
            firstWordStart: Transcript.start(of: piece.text, startingAt: transcript.consumedThrough)
        )
    }

    private func checkForPause() {
        // What the audio and synthesizer threads recorded, written here on the main actor.
        pipeline?.timeline.writeRecorded()
        pauseDetector.pauseThreshold = pauseThreshold
        if pipeline?.voiceActivity.takeHeardVoice() == true {
            pauseDetector.heardVoice(at: .now)
        }
        guard pauseDetector.isComplete(at: .now) else { return }
        // For the timeline log, before they are cleared.
        let words = transcript.wordCount
        let pause = pauseDetector
        let utterance = transcript.take()
        pauseDetector.reset()
        if !utterance.text.isEmpty {
            pipeline?.timeline.utteranceSent(
                words: words,
                lastVoice: pause.lastVoice,
                lastChange: pause.lastChange,
                endsSentence: PauseDetector.endsSentence(utterance.text)
            )
            utteranceContinuation.yield(utterance)
        }
        updateListeningState()
        speakNextIfIdle()
    }

    private func updateListeningState() {
        guard pipeline != nil else { return }
        state = currentSpeech == nil ? .listening(partial: transcript.text) : .speaking
    }

    private enum Teardown {
        /// Voice mode ends: the queue is cleared, the iOS session deactivated, no resume is
        /// pending after an interruption, and `state` is `.off`. If the engine is running, it
        /// plays the stop cue first, and the session is deactivated after that.
        case stop
        /// The engine is about to be rebuilt: the queue is kept, with the message that was cut
        /// off back at the front, and `state` stays `.listening(partial: "")`. The iOS session
        /// stays active, because a backgrounded app may not be allowed to activate a recording
        /// session again.
        case rebuild
    }

    private func tearDown(_ kind: Teardown) {
        runID += 1
        if kind == .rebuild, let currentSpeech {
            speechQueue.insert(currentSpeech.text, at: 0)
        }
        silence(consumingEcho: true, reason: "teardown")
        if kind == .stop {
            speechQueue.removeAll()
        }
        transcript = Transcript()
        pauseDetector.reset()
        // A cue cut off here isn't played again; the next start plays its own.
        unfinishedCues = []
        if let pipeline {
            self.pipeline = nil
            // No stop cue for a rebuild, or for an engine that has stopped (an interruption, or
            // one that keeps stopping).
            if kind == .stop && playsSoundCues && pipeline.engine.isRunning {
                close(pipeline)
            } else {
                pipeline.tearDown()
            }
            // What its tap recorded since the last 100 ms poll, now that the tap is gone (both
            // paths remove it).
            pipeline.timeline.writeRecorded()
            if let recognizer = pipeline.recognizer {
                Task { await recognizer.cancel() }
            }
        }
        if kind == .stop {
            // Also covers a failed restart, whose session was kept active across the rebuild.
            // A pipeline playing the stop cue deactivates it when it's done.
            if closingPipeline == nil {
                Self.deactivateAudioSession()
            }
            resumeAfterInterruption = false
            recentEngineStops = []
            if state != .off {
                Self.log.notice("voice mode stopped")
            }
        }
        state = kind == .stop ? .off : .listening(partial: "")
    }

    /// Stops listening on `pipeline` at once, but keeps its engine running to play the stop cue,
    /// then tears it down and deactivates the iOS session. A start that builds a new engine
    /// meanwhile ends it sooner, with `endClosingPipeline()`.
    private func close(_ pipeline: Pipeline) {
        pipeline.stopListening()
        // The stop cue replaces any cue still playing.
        pipeline.cuePlayer.stop()
        pipeline.play(.listeningStopped) {}
        closingPipeline = pipeline
        // A timer rather than the cue's completion, which can come early or not at all if the
        // engine stops by itself. It holds the loop until then, so the engine is always stopped.
        let wait = SoundCue.listeningStopped.duration + Self.stopCueMargin
        pipeline.tasks = [Task { [self] in
            do {
                try await Task.sleep(for: wait)
            } catch {
                // A new start ended the pipeline first, and owns the session now.
                return
            }
            guard closingPipeline === pipeline else { return }
            closingPipeline = nil
            pipeline.tearDown()
            Self.deactivateAudioSession()
        }]
    }

    /// Ends the pipeline playing the stop cue now, cutting the cue short. For a start about to
    /// build a new engine, which activates the iOS session itself, so it isn't deactivated.
    private func endClosingPipeline() {
        guard let closingPipeline else { return }
        self.closingPipeline = nil
        closingPipeline.tearDown()
    }

    /// How much longer than the stop cue its engine keeps running. On a device the sound
    /// reaches the speaker, or AirPods, a little after it is rendered.
    private static let stopCueMargin: Duration = .milliseconds(250)

    /// The engine stopped itself because the audio hardware changed. Starts the same engine
    /// again, keeping the analyzer and the utterance in progress, and rebuilds everything if
    /// that fails. A reply being spoken starts over, and so does a cue that hadn't finished.
    ///
    /// If the engine keeps stopping, starting it again won't help, so the loop turns off instead
    /// of trying forever. `source` says what noticed the stop, for the logs.
    private func engineStopped(_ pipeline: Pipeline, source: String) {
        let now = ContinuousClock.now
        recentEngineStops = recentEngineStops.filter { $0.duration(to: now) < Self.engineStopWindow } + [now]
        guard recentEngineStops.count <= Self.maxEngineStopsPerWindow else {
            Self.log.error(
                "audio engine keeps stopping; giving up",
                pipeline.formatContext.merging(["stops": "\(recentEngineStops.count)", "source": source]) { $1 }
            )
            tearDown(.stop)
            return
        }
        Self.log.notice("audio engine stopped", pipeline.formatContext.merging(["source": source]) { $1 })
        if let currentSpeech {
            speechQueue.insert(currentSpeech.text, at: 0)
        }
        silence(consumingEcho: true, reason: "engineStopped")
        // On the iPhone every new engine stops once right after it starts, cutting off the
        // start cue.
        let interruptedCues = unfinishedCues.map(\.cue)
        unfinishedCues = []
        pipeline.cuePlayer.stop()
        do {
            try pipeline.restartEngine()
            Self.log.notice("audio engine restarted", pipeline.formatContext)
            for cue in interruptedCues {
                play(cue)
            }
            speakNextIfIdle()
        } catch {
            Self.log.warning("restarting the audio engine failed; rebuilding", error.logContext(pipeline.formatContext))
            restart()
        }
    }

    private static let engineStopWindow: Duration = .seconds(10)
    private static let maxEngineStopsPerWindow = 3

    /// Rebuilds everything after the engine stopped and couldn't be started again, or to apply
    /// a changed `pausesOtherAudio`. If starting fails, `start()` turns the loop off.
    ///
    /// `resettingAudioSession` also deactivates the iOS session before the rebuild, so audio it
    /// interrupted can resume and the new start activates it with the new options. Only for a
    /// change made in the app's UI: a backgrounded app may not be allowed to activate a
    /// recording session again.
    private func restart(resettingAudioSession: Bool = false) {
        tearDown(.rebuild)
        if resettingAudioSession {
            // A new engine for a settings change, not one that stopped on its own.
            recentEngineStops = []
            Self.deactivateAudioSession()
        }
        startInTask { error in
            Self.log.error("voice loop rebuild failed", error.logContext())
        }
    }

    /// Calls `start()` from a new task, unless a teardown (such as `stop()`) comes before that
    /// task runs: starting then would undo the stop, leaving the loop running after the app
    /// turned voice mode off.
    private func startInTask(isForegroundRetry: Bool = false, onFailure: @escaping (any Error) -> Void) {
        let run = runID
        Task {
            guard run == runID else { return }
            do {
                try await start(isForegroundRetry: isForegroundRetry)
            } catch {
                onFailure(error)
            }
        }
    }

    // MARK: - Audio session

    /// Sets up and activates the iOS session for an engine with or without voice processing.
    /// Without `pausingOtherAudio` the session mixes with other apps' audio instead of
    /// interrupting it. macOS has no audio session; there only voice processing affects other audio.
    private static func activateAudioSession(voiceProcessing: Bool, pausingOtherAudio: Bool) throws {
        #if os(iOS)
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
        if !pausingOtherAudio {
            options.insert(.mixWithOthers)
        }
        let session = AVAudioSession.sharedInstance()
        // Voice processing is meant for a chat mode, and iOS switches the session to voice chat
        // (call volume) once it runs anyway. Without voice processing, voice chat would only
        // lower the playback level.
        let mode: AVAudioSession.Mode = voiceProcessing ? .voiceChat : .default
        try session.setCategory(.playAndRecord, mode: mode, options: options)
        try session.setActive(true)
        #endif
    }

    /// Also used by the preview player once a preview ends.
    static func deactivateAudioSession() {
        #if os(iOS)
        // Lets other apps' audio resume. It fails only if the session is already inactive
        // (after an interruption) or still busy, and there is nothing more to do either way.
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            log.debug("audio session deactivation failed", error.logContext())
        }
        #endif
    }

    /// Follows changes to the system's voices, and on iOS the audio session's interruptions and
    /// the app coming to the foreground.
    private func observeSystem() {
        let voiceChanges = NotificationCenter.default.notifications(named: AVSpeechSynthesizer.availableVoicesDidChangeNotification)
        Task { [weak self] in
            for await _ in voiceChanges {
                guard let self else { return }
                self.withMutation(keyPath: \.voices) {
                    self.systemVoiceCache = nil
                }
            }
        }
        #if os(iOS)
        let interruptions = NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification)
            .map { InterruptionEvent($0) }
        Task { [weak self] in
            for await event in interruptions {
                guard let self else { return }
                self.handleInterruption(event)
            }
        }
        let activations = NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification)
        Task { [weak self] in
            for await _ in activations {
                guard let self else { return }
                self.resumeIfInterruptionNeverEnded()
            }
        }
        #endif
    }

    #if os(iOS)
    /// Another app (a call, FaceTime, Music) can keep the session, and then iOS never sends
    /// the interruption's end. Coming back to the foreground retries instead. The retry may
    /// run while the interruption is still active (Adam returns mid-call, or the call UI
    /// closes just before the end arrives). If it fails, the loop shows `.off` but still
    /// resumes on a later `.ended(shouldResume: true)`.
    private func resumeIfInterruptionNeverEnded() {
        guard resumeAfterInterruption else { return }
        resumeAfterInterruption = false
        startInTask(isForegroundRetry: true) { error in
            Self.log.warning("voice loop resume on foreground failed", error.logContext())
        }
    }

    private func handleInterruption(_ event: InterruptionEvent?) {
        switch event {
        case .began:
            // iOS has already stopped the engine and deactivated the session. Restart from
            // scratch when it's over. A start in progress (say, a restart) is abandoned.
            guard pipeline != nil || isStarting else { return }
            tearDown(.rebuild)
            resumeAfterInterruption = true
        case .ended(let shouldResume):
            guard resumeAfterInterruption else { return }
            resumeAfterInterruption = false
            guard shouldResume else {
                // iOS doesn't allow resuming, so voice mode is over.
                tearDown(.stop)
                return
            }
            // If starting fails, `start()` turns the loop off.
            startInTask { error in
                Self.log.error("voice loop resume after interruption failed", error.logContext())
            }
        case nil:
            break
        }
    }
    #endif

    // MARK: - Speaking

    private func speakNextIfIdle() {
        guard let pipeline, pipeline.engine.isRunning, currentSpeech == nil, transcript.isEmpty,
              !speechQueue.isEmpty else { return }
        let text = speechQueue.removeFirst()
        // Each message takes the pitch as it is now, also on a new or restarted engine.
        pipeline.speech.setPitch(speechPitch)
        let playback = pipeline.speech.makePlayback(text: text) { [weak self] playback in
            Task { @MainActor in self?.speechFinished(playback) }
        }
        currentSpeech = playback
        state = .speaking
        // The reply's log reports what the microphone heard while it played.
        _ = pipeline.voiceActivity.takePeakDecibels()
        ignoredResultsThisReply = 0
        // Right before synthesis starts: the timeline measures the reply from here, whichever
        // voice renders it.
        let started = TimelineClock.now()
        synthesize(text, into: playback)
        pipeline.speech.player.play()
        pipeline.timeline.speechStarted(at: started, chars: text.count, queued: speechQueue.count) {
            playback.firstAudioHostTime
        }
    }

    /// Renders `text` into `playback` in the chosen voice and speed: with Kokoro when a Kokoro
    /// voice is chosen and its model is ready, otherwise with the system synthesizer.
    private func synthesize(_ text: String, into playback: SpeechPlayback) {
        if let voice = readyKokoroVoice() {
            kokoroSynthesis = synthesizeWithKokoro(text, voice: voice, into: playback) { [self] rest in
                synthesizeWithSystemVoice(rest, into: playback)
            }
        } else {
            synthesizeWithSystemVoice(text, into: playback)
        }
    }

    private func synthesizeWithSystemVoice(_ text: String, into playback: SpeechPlayback) {
        let utterance = makeUtterance(text)
        synthesisObserver.track(utterance, playback: playback)
        synthesizer.write(utterance) { @Sendable buffer in
            playback.receive(buffer)
        }
    }

    /// The chosen Kokoro voice's id, if a Kokoro voice is chosen and its model is ready.
    private func readyKokoroVoice() -> String? {
        guard kokoroModel.state == .ready, let chosen = chosenVoice, chosen.engine == .kokoro else { return nil }
        return KokoroCatalog.kokoroVoice(forOptionID: chosen.id)
    }

    /// Kokoro doesn't stream, so `text` is rendered a sentence at a time off the main actor, and
    /// each sentence is fed to `playback` once it's ready. Cancelling the returned task stops
    /// it: no further sentence is rendered, and the caller cancels `playback` too, so the one
    /// rendering then is dropped. If rendering fails, or the model is freed because another
    /// voice was chosen, `systemVoice` is handed the rest of the text to say.
    private func synthesizeWithKokoro(
        _ text: String,
        voice: String,
        into playback: SpeechPlayback,
        systemVoice: @escaping @MainActor (String) -> Void
    ) -> Task<Void, Never> {
        let sentences = KokoroText.sentences(in: text)
        let speed = KokoroSpeed.speed(forRate: speechRate)
        let engine = kokoroModel.engine
        return Task {
            // Kokoro can't pronounce digits. Only its text is changed: the system voice gets
            // the sentences as written.
            let numbers = KokoroNumbers()
            for (index, sentence) in sentences.enumerated() {
                guard !Task.isCancelled else { return }
                guard kokoroModel.state == .ready else {
                    // Another voice was chosen, which freed the model.
                    systemVoice(sentences[index...].joined(separator: " "))
                    return
                }
                let samples: [Float]
                do {
                    samples = try await engine.synthesize(numbers.spelledOut(sentence), voice: voice, speed: speed)
                } catch {
                    guard !Task.isCancelled else { return }
                    // Codes only: KokoroTTS's messages can list voices and paths.
                    Self.log.error(
                        "kokoro synthesis failed; speaking with the system voice",
                        error.logCodes(["sentence": "\(index)", "sentences": "\(sentences.count)"])
                    )
                    systemVoice(sentences[index...].joined(separator: " "))
                    return
                }
                guard !Task.isCancelled else { return }
                for buffer in KokoroAudio.buffers(samples) {
                    playback.receive(buffer)
                }
            }
            guard !Task.isCancelled else { return }
            playback.synthesisFinished()
        }
    }

    /// Starts loading the Kokoro model if a Kokoro voice is chosen.
    private func loadKokoroModelIfChosen() {
        guard isKokoroVoiceChosen else { return }
        kokoroModel.load()
    }

    private var isKokoroVoiceChosen: Bool {
        chosenVoice?.engine == .kokoro
    }

    private func speechFinished(_ playback: SpeechPlayback) {
        guard currentSpeech === playback else { return }
        let replyEnded = logReplyEnded(playback, reason: "finished")
        pipeline?.timeline.speechFinished(replyEnded)
        currentSpeech = nil
        kokoroSynthesis = nil
        consumeEcho()
        updateListeningState()
        speakNextIfIdle()
    }

    /// The cue `play(_:)` gave `id` has played, or its player was stopped. An engine that stops
    /// itself stops its players too, before the loop hears of it; a cue cut off that way stays
    /// unfinished, to play again once the engine is running again.
    private func cueFinished(_ id: Int) {
        guard pipeline?.engine.isRunning == true else { return }
        unfinishedCues.removeAll { $0.id == id }
    }

    /// Stops the message being spoken, leaving the queue alone. A barge-in passes
    /// `consumingEcho: false`, since the audio heard while speaking is the user's. `reason`
    /// says why, for the logs.
    private func silence(consumingEcho: Bool, reason: String) {
        guard let currentSpeech else { return }
        pipeline?.timeline.speechStopRequested(reason: reason)
        logReplyEnded(currentSpeech, reason: reason)
        self.currentSpeech = nil
        currentSpeech.cancel()
        kokoroSynthesis?.cancel()
        kokoroSynthesis = nil
        synthesizer.stopSpeaking(at: .immediate)
        if let pipeline {
            pipeline.speech.player.stop()
            pipeline.timeline.speechStopped(outputLatency: pipeline.engine.outputNode.presentationLatency)
        }
        if consumingEcho {
            consumeEcho()
        }
        ignoredWhileSpeaking = false
        updateListeningState()
    }

    /// Logs how a reply ended and the loudest microphone level while it played, after echo
    /// cancellation. That level includes the user talking and room noise as well as any of the
    /// reply that got through, so it only measures leakage for a reply that played to the end
    /// in a quiet room. Counts and levels only. `kokoro` says whether Kokoro rendered the reply
    /// (or its start, if it failed partway) rather than the system voice. Returns the line's
    /// fields, which "speech finished" on the timeline repeats: taking the peak level resets it.
    @discardableResult
    private func logReplyEnded(_ playback: SpeechPlayback, reason: String) -> [String: CustomStringConvertible] {
        let fields: [String: CustomStringConvertible] = [
            "reason": reason,
            "kokoro": kokoroSynthesis != nil,
            "ms": Int(playback.started.duration(to: .now) / .milliseconds(1)),
            "ignoredResults": ignoredResultsThisReply,
            "micPeakDb": pipeline?.voiceActivity.takePeakDecibels() ?? -120,
            "echoCancellation": pipeline?.hasVoiceProcessing ?? false,
        ]
        Self.log.info("reply ended", fields)
        return fields
    }

    /// Once speaking ends, its echo must not be sent later. See `ignoredWhileSpeaking` for
    /// when the audio fed so far is consumed.
    private func consumeEcho() {
        guard let pipeline else { return }
        if !pipeline.hasVoiceProcessing {
            // The fed audio lags the speaker by a tap buffer plus device latency, and without
            // echo cancellation the reply's last moment reaches the microphone at full volume.
            // Consume a little past it, so a reply cut off mid-word isn't heard as a word.
            transcript.consume(through: pipeline.fedAudio.time + Self.halfDuplexEchoMargin)
        } else if ignoredWhileSpeaking || bargeInMinimumWords > 1 {
            transcript.consume(through: pipeline.fedAudio.time)
        }
        ignoredWhileSpeaking = false
    }

    /// Words starting this soon after a reply ends are dropped when there is no echo cancellation.
    private static let halfDuplexEchoMargin = CMTime(value: 3, timescale: 10)

    /// `text` in the chosen voice and speed.
    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice()
        utterance.rate = speechRate
        return utterance
    }

    /// The chosen system voice, or the best one on offer when none is chosen, a Kokoro voice is
    /// chosen, or the chosen voice isn't on offer (see `chosenVoice`).
    private func voice() -> AVSpeechSynthesisVoice? {
        let voices = voices
        let chosen = voices.first { $0.id == voiceIdentifier && $0.engine == .system }
        let system = chosen ?? voices.first { $0.engine == .system }
        return system.flatMap { AVSpeechSynthesisVoice(identifier: $0.id) }
    }
}

/// A text-to-speech voice the user can pick.
public struct VoiceOption: Identifiable, Hashable, Sendable {
    /// `AVSpeechSynthesisVoice.identifier` for a system voice. For a Kokoro voice, `kokoro.`
    /// and its Kokoro voice id, such as `kokoro.af_heart`.
    public let id: String
    public let name: String
    /// A system voice's quality. Kokoro voices have no quality levels, and are `.standard`.
    public let quality: Quality
    public let engine: Engine

    public enum Quality: Int, Comparable, Sendable {
        case standard, enhanced, premium
        public static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// What speaks with the voice.
    public enum Engine: Sendable {
        /// `AVSpeechSynthesizer`.
        case system
        /// The Kokoro-82M neural model, which runs on the device and is downloaded the first
        /// time a Kokoro voice is used.
        case kokoro
    }

    public init(id: String, name: String, quality: Quality, engine: Engine = .system) {
        self.id = id
        self.name = name
        self.quality = quality
        self.engine = engine
    }
}

extension VoiceOption.Quality {
    init(_ quality: AVSpeechSynthesisVoiceQuality) {
        switch quality {
        case .premium: self = .premium
        case .enhanced: self = .enhanced
        default: self = .standard
        }
    }
}

public enum VoiceLoopError: Error, Sendable, Equatable {
    case microphonePermissionDenied
    case speechPermissionDenied
    case speechModelUnavailable
}

#if os(iOS)
/// The parts of an `AVAudioSession` interruption notification the loop and the preview player
/// act on.
enum InterruptionEvent: Sendable {
    case began
    case ended(shouldResume: Bool)

    init?(_ notification: Notification) {
        guard let info = notification.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return nil }
        switch type {
        case .began:
            self = .began
        case .ended:
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            self = .ended(shouldResume: AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume))
        @unknown default:
            return nil
        }
    }
}
#endif
