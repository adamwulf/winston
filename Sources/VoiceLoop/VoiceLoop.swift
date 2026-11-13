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
/// interrupts). Speech is rendered with
/// `AVSpeechSynthesizer.write(_:toBufferCallback:)` and played on an `AVAudioPlayerNode` in
/// the same engine.
@MainActor
@Observable
public final class VoiceLoop {
    private nonisolated static let log = Logger(label: "voice.loop")

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
    /// `AVSpeechSynthesisVoice.identifier` to speak with; nil picks the best installed voice.
    public var voiceIdentifier: String?
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

    /// One element per finished utterance. Iterate it from one long-lived task (for example
    /// the app model): it has a single consumer, and cancelling that iteration ends the
    /// stream for good.
    @ObservationIgnored public let utterances: AsyncStream<Utterance>
    @ObservationIgnored private let utteranceContinuation: AsyncStream<Utterance>.Continuation

    /// The running engine and analyzer. Nil while off, while starting, and during a rebuild
    /// or an interruption (when `state` is still `.listening`).
    @ObservationIgnored private var pipeline: Pipeline?
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
    /// Plays voice previews when the loop isn't running. See `preview(_:)`.
    @ObservationIgnored private let previewSynthesizer = AVSpeechSynthesizer()
    /// The synthesizer's delegate (held strongly; `delegate` is weak). Tells the playback
    /// when synthesis has finished.
    @ObservationIgnored private let synthesisObserver = SynthesisObserver()
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
    /// Set once voice processing fails to start, so later starts go straight to an engine
    /// without it (a failed attempt can block the main thread for seconds).
    @ObservationIgnored private var skipVoiceProcessing = false

    public init() {
        (utterances, utteranceContinuation) = AsyncStream.makeStream(of: Utterance.self)
        synthesizer.delegate = synthesisObserver
        #if os(iOS)
        // Its own playback session, so the silent switch doesn't mute previews and the
        // session voice mode sets up isn't touched.
        previewSynthesizer.usesApplicationAudioSession = false
        #endif
        observeAppAndSession()
    }

    // MARK: - Public API

    /// Starts listening. Asks for microphone and speech permission on first use.
    ///
    /// Throws a `VoiceLoopError` when permission is missing or the speech model can't be
    /// installed, and passes audio engine errors through. Does nothing if already running.
    public func start() async throws {
        try await start(isForegroundRetry: false)
    }

    /// `isForegroundRetry` marks the retry after an interruption iOS never reported ending.
    /// If it fails, the interruption may still be live, so a later end still resumes the loop.
    private func start(isForegroundRetry: Bool) async throws {
        guard pipeline == nil, !isStarting else { return }
        // A preview playing outside the engine would be heard as speech once listening starts.
        previewSynthesizer.stopSpeaking(at: .immediate)
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
        try await Self.requestPermissions()
        let transcriber = try await Self.makeTranscriber()
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceLoopError.speechModelUnavailable
        }
        guard run == runID else { return }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        var newPipeline: Pipeline?
        do {
            let pipeline = try makeRunningPipeline(analyzerFormat: analyzerFormat)
            newPipeline = pipeline
            // Microphone buffers queue in `pipeline.inputs` until the analyzer starts reading.
            try await analyzer.start(inputSequence: pipeline.inputs)
        } catch {
            newPipeline?.tearDown()
            await analyzer.cancelAndFinishNow()
            Self.deactivateAudioSession()
            throw error
        }
        guard let pipeline = newPipeline, run == runID else {
            // stop() or an interruption came while the analyzer was starting.
            newPipeline?.tearDown()
            await analyzer.cancelAndFinishNow()
            Self.deactivateAudioSession()
            return
        }

        pipeline.analyzer = analyzer
        self.pipeline = pipeline
        resumeAfterInterruption = false
        state = .listening(partial: "")
        // Also after a rebuild (a route change or an interruption), which has no "stopped" before it.
        Self.log.notice(
            "voice mode started",
            pipeline.formatContext.merging(["echoCancellation": "\(pipeline.hasVoiceProcessing)"]) { $1 }
        )

        let configurationChanges = NotificationCenter.default.notifications(
            named: .AVAudioEngineConfigurationChange,
            object: pipeline.engine
        )
        pipeline.tasks = [
            Task { [weak self] in
                await self?.listen(to: transcriber, in: pipeline)
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
        // Replies carried over a rebuild, or queued while starting. Does nothing if the engine
        // is being rebuilt.
        speakNextIfIdle()
    }

    /// Activates the iOS session and builds and starts the engine with voice processing (echo
    /// cancellation), or without it if voice processing can't start. Without echo cancellation
    /// the loop is half-duplex: replies can't be interrupted by voice.
    private func makeRunningPipeline(analyzerFormat: AVAudioFormat) throws -> Pipeline {
        let pausingOtherAudio = pausesOtherAudio
        func started(voiceProcessing: Bool) throws -> Pipeline {
            try Self.startedPipeline(
                analyzerFormat: analyzerFormat,
                voiceProcessing: voiceProcessing,
                ducksOtherAudio: pausingOtherAudio
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

    private static func startedPipeline(
        analyzerFormat: AVAudioFormat,
        voiceProcessing: Bool,
        ducksOtherAudio: Bool
    ) throws -> Pipeline {
        let pipeline = try Pipeline(
            analyzerFormat: analyzerFormat,
            voiceProcessing: voiceProcessing,
            ducksOtherAudio: ducksOtherAudio
        )
        do {
            try pipeline.engine.start()
        } catch {
            pipeline.tearDown()
            throw error
        }
        return pipeline
    }

    /// Stops listening and speaking.
    public func stop() {
        tearDown(.stop)
    }

    /// Drops the utterance in progress without sending it.
    public func discardCurrentUtterance() {
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
        silence(consumingEcho: true)
    }

    /// Says `text` right away in the current voice, for trying voices in settings, cutting off
    /// an earlier preview. While the loop is running it also stops any reply being spoken and
    /// drops queued ones, and it plays through the loop's engine, so echo cancellation (or
    /// half-duplex) keeps it out of the transcript. Otherwise it plays straight to the speaker.
    public func preview(_ text: String) {
        previewSynthesizer.stopSpeaking(at: .immediate)
        // Starting or rebuilding counts as running: speak() queues for the engine then, and
        // a preview played outside it would reach the microphone and be sent as speech.
        if state != .off || isStarting {
            stopSpeaking()
            speak(text)
        } else {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice()
            previewSynthesizer.speak(utterance)
        }
    }

    /// Installed voices for the current language, best quality first, for a settings picker.
    /// Within a quality, the system's default voice comes first, then by name. Novelty voices
    /// are left out.
    public static func availableVoices() -> [VoiceOption] {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
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

    /// Feeds transcriber results into the transcript until the pipeline is torn down.
    private func listen(to transcriber: SpeechTranscriber, in pipeline: Pipeline) async {
        do {
            for try await result in transcriber.results {
                // Results can still arrive after a teardown; they belong to the old session.
                guard self.pipeline === pipeline else { return }
                handle(TranscriptPiece(result))
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
                ignoredWhileSpeaking = true
                return
            }
            // Barge-in: speech over the reply stops it and becomes the next utterance. Results
            // ignored so far may be this utterance's first words, so no audio is consumed.
            speechQueue.removeAll()
            silence(consumingEcho: false)
        }
        transcript = candidate
        pauseDetector.update(text: transcript.text, at: .now)
        updateListeningState()
        // An empty or revoked result can end the utterance a held reply was waiting on.
        speakNextIfIdle()
    }

    private func checkForPause() {
        pauseDetector.pauseThreshold = pauseThreshold
        if pipeline?.voiceActivity.takeHeardVoice() == true {
            pauseDetector.heardVoice(at: .now)
        }
        guard pauseDetector.isComplete(at: .now) else { return }
        let utterance = transcript.take()
        pauseDetector.reset()
        if !utterance.text.isEmpty {
            utteranceContinuation.yield(utterance)
        }
        updateListeningState()
        speakNextIfIdle()
    }

    private func updateListeningState() {
        guard pipeline != nil else { return }
        state = currentSpeech == nil ? .listening(partial: transcript.text) : .speaking
    }

    private static func requestPermissions() async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw VoiceLoopError.microphonePermissionDenied
        }
        guard await requestSpeechAuthorization() == .authorized else {
            throw VoiceLoopError.speechPermissionDenied
        }
    }

    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    /// A transcriber for the current locale, with its model installed.
    private static func makeTranscriber() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw VoiceLoopError.speechModelUnavailable
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .alternativeTranscriptions],
            attributeOptions: [.audioTimeRange]
        )
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            log.error("speech model install failed", error.logContext())
            throw VoiceLoopError.speechModelUnavailable
        }
        return transcriber
    }

    private enum Teardown {
        /// Voice mode ends: the queue is cleared, the iOS session deactivated, no resume is
        /// pending after an interruption, and `state` is `.off`.
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
        silence(consumingEcho: true)
        if kind == .stop {
            speechQueue.removeAll()
        }
        transcript = Transcript()
        pauseDetector.reset()
        if let pipeline {
            self.pipeline = nil
            pipeline.tearDown()
            if let analyzer = pipeline.analyzer {
                Task { await analyzer.cancelAndFinishNow() }
            }
        }
        if kind == .stop {
            // Also covers a failed restart, whose session was kept active across the rebuild.
            Self.deactivateAudioSession()
            resumeAfterInterruption = false
            recentEngineStops = []
            if state != .off {
                Self.log.notice("voice mode stopped")
            }
        }
        state = kind == .stop ? .off : .listening(partial: "")
    }

    /// The engine stopped itself because the audio hardware changed. Starts the same engine
    /// again, keeping the analyzer and the utterance in progress, and rebuilds everything if
    /// that fails. A reply being spoken starts over.
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
        silence(consumingEcho: true)
        do {
            try pipeline.restartEngine()
            Self.log.notice("audio engine restarted", pipeline.formatContext)
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

    private static func deactivateAudioSession() {
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

    private func observeAppAndSession() {
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
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice()
        let playback = SpeechPlayback(text: text, player: pipeline.player, format: pipeline.speechFormat) { [weak self] playback in
            Task { @MainActor in self?.speechFinished(playback) }
        }
        currentSpeech = playback
        state = .speaking
        synthesisObserver.track(utterance, playback: playback)
        synthesizer.write(utterance) { @Sendable buffer in
            playback.receive(buffer)
        }
        pipeline.player.play()
    }

    private func speechFinished(_ playback: SpeechPlayback) {
        guard currentSpeech === playback else { return }
        currentSpeech = nil
        consumeEcho()
        updateListeningState()
        speakNextIfIdle()
    }

    /// Stops the message being spoken, leaving the queue alone. A barge-in passes
    /// `consumingEcho: false`, since the audio heard while speaking is the user's.
    private func silence(consumingEcho: Bool) {
        guard let currentSpeech else { return }
        self.currentSpeech = nil
        currentSpeech.cancel()
        synthesizer.stopSpeaking(at: .immediate)
        pipeline?.player.stop()
        if consumingEcho {
            consumeEcho()
        }
        ignoredWhileSpeaking = false
        updateListeningState()
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

    private func voice() -> AVSpeechSynthesisVoice? {
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            return voice
        }
        return Self.availableVoices().first.flatMap { AVSpeechSynthesisVoice(identifier: $0.id) }
    }
}

/// A text-to-speech voice the user can pick.
public struct VoiceOption: Identifiable, Hashable, Sendable {
    /// `AVSpeechSynthesisVoice.identifier`.
    public let id: String
    public let name: String
    public let quality: Quality

    public enum Quality: Int, Comparable, Sendable {
        case standard, enhanced, premium
        public static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public init(id: String, name: String, quality: Quality) {
        self.id = id
        self.name = name
        self.quality = quality
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

extension TranscriptPiece {
    init(_ result: SpeechTranscriber.Result) {
        self.init(text: result.text, alternatives: result.alternatives, range: result.range, isFinal: result.isFinal)
    }
}

#if os(iOS)
/// The parts of an `AVAudioSession` interruption notification the loop acts on.
private enum InterruptionEvent: Sendable {
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
