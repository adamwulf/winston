import AVFoundation
import Foundation
import Observation
import Speech

/// Hands-free voice loop: listens, detects the end of an utterance, speaks replies,
/// and stops speaking when the user talks over it (barge-in).
///
/// One `AVAudioEngine` does everything. Its input node has voice processing on, so the app's
/// own speech is removed from the microphone signal, and feeds a `SpeechAnalyzer` running
/// `SpeechTranscriber`. Speech is rendered with `AVSpeechSynthesizer.write(_:toBufferCallback:)`
/// and played on an `AVAudioPlayerNode` in the same engine.
@MainActor
@Observable
public final class VoiceLoop {
    public enum State: Sendable, Equatable {
        case off
        /// Listening; `partial` is the live transcript of the current utterance (may be empty).
        case listening(partial: String)
        /// Speaking a reply. Listening continues so the user can interrupt.
        case speaking
    }

    /// `.off` until `start()` succeeds, and again after `stop()` or when the loop stops on its
    /// own (an audio interruption it can't resume from, or a transcriber failure).
    public private(set) var state: State = .off
    /// How long the transcript must stay unchanged before an utterance is finished.
    public var pauseThreshold: Duration = .milliseconds(1200)
    /// `AVSpeechSynthesisVoice.identifier` to speak with; nil picks the best installed voice.
    public var voiceIdentifier: String?
    /// While speaking, transcripts with fewer words than this are ignored instead of
    /// interrupting. Raise it if the app's own voice leaks through echo cancellation.
    public var bargeInMinimumWords = 1

    /// One element per finished utterance. Single consumer.
    @ObservationIgnored public let utterances: AsyncStream<Utterance>
    @ObservationIgnored private let utteranceContinuation: AsyncStream<Utterance>.Continuation

    /// The running engine and analyzer; nil while off.
    @ObservationIgnored private var pipeline: Pipeline?
    /// True while `start()` is running, so a second call doesn't start a second pipeline.
    @ObservationIgnored private var isStarting = false
    /// Bumped by every teardown, so a `start()` that was overtaken by `stop()` gives up.
    @ObservationIgnored private var runID = 0
    /// Set when an interruption stopped the loop, so it restarts when the interruption ends.
    @ObservationIgnored private var resumeAfterInterruption = false

    @ObservationIgnored private var transcript = Transcript()
    @ObservationIgnored private var pauseDetector = PauseDetector(pauseThreshold: .milliseconds(1200))

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var speechQueue: [String] = []
    /// The message being rendered and played; nil when not speaking.
    @ObservationIgnored private var currentSpeech: SpeechPlayback?

    public init() {
        (utterances, utteranceContinuation) = AsyncStream.makeStream(of: Utterance.self)
        observeInterruptions()
    }

    // MARK: - Public API

    /// Starts listening. Asks for microphone and speech permission on first use.
    ///
    /// Throws a `VoiceLoopError` when permission is missing or the speech model can't be
    /// installed, and passes audio engine errors through. Does nothing if already running.
    public func start() async throws {
        guard pipeline == nil, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        let run = runID

        try await Self.requestPermissions()
        let transcriber = try await Self.makeTranscriber()
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceLoopError.speechModelUnavailable
        }
        guard run == runID else { return }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        var newPipeline: Pipeline?
        do {
            try Self.activateAudioSession()
            let pipeline = try Pipeline(analyzerFormat: analyzerFormat)
            newPipeline = pipeline
            try await analyzer.start(inputSequence: pipeline.inputs)
            if run == runID {
                try pipeline.engine.start()
            }
        } catch {
            newPipeline?.tearDown()
            await analyzer.cancelAndFinishNow()
            Self.deactivateAudioSession()
            throw error
        }
        guard let pipeline = newPipeline, run == runID else {
            // stop() was called while the analyzer was starting.
            newPipeline?.tearDown()
            await analyzer.cancelAndFinishNow()
            Self.deactivateAudioSession()
            return
        }

        pipeline.analyzer = analyzer
        self.pipeline = pipeline
        resumeAfterInterruption = false
        state = .listening(partial: "")

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
                // AirPods connect. Rebuild it so listening carries on.
                for await _ in configurationChanges {
                    guard let self, let pipeline, self.pipeline === pipeline else { return }
                    if !pipeline.engine.isRunning {
                        self.restart()
                        return
                    }
                }
            },
        ]
    }

    /// Stops listening and speaking.
    public func stop() {
        resumeAfterInterruption = false
        tearDown(deactivatingSession: true)
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
    /// Ignored while the loop is off. A message waits while an utterance is in progress, so
    /// the reply doesn't start over the user and get cut off by barge-in.
    public func speak(_ text: String) {
        guard pipeline != nil else { return }
        let spoken = SpokenText.speakable(text)
        guard !spoken.isEmpty else { return }
        speechQueue.append(spoken)
        speakNextIfIdle()
    }

    /// Stops speaking and clears the queue.
    public func stopSpeaking() {
        speechQueue.removeAll()
        guard let currentSpeech else { return }
        self.currentSpeech = nil
        currentSpeech.cancel()
        synthesizer.stopSpeaking(at: .immediate)
        pipeline?.player.stop()
        updateListeningState()
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
        }
        // The results ended while this pipeline is still running, so nothing more can be heard.
        if self.pipeline === pipeline {
            tearDown(deactivatingSession: true)
        }
    }

    private func handle(_ piece: TranscriptPiece) {
        var candidate = transcript
        guard candidate.apply(piece) else { return }
        if currentSpeech != nil {
            // Barge-in: speech over the reply stops it and becomes the next utterance.
            guard candidate.wordCount >= max(1, bargeInMinimumWords) else { return }
            stopSpeaking()
        }
        transcript = candidate
        pauseDetector.update(text: transcript.text, at: .now)
        updateListeningState()
    }

    private func checkForPause() {
        pauseDetector.pauseThreshold = pauseThreshold
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
            throw VoiceLoopError.speechModelUnavailable
        }
        return transcriber
    }

    /// Stops everything and sets `state = .off`. A restart keeps the iOS audio session active,
    /// because a backgrounded app may not be allowed to activate a recording session again.
    private func tearDown(deactivatingSession: Bool) {
        runID += 1
        stopSpeaking()
        transcript = Transcript()
        pauseDetector.reset()
        if let pipeline {
            self.pipeline = nil
            pipeline.tearDown()
            if let analyzer = pipeline.analyzer {
                Task { await analyzer.cancelAndFinishNow() }
            }
            if deactivatingSession {
                Self.deactivateAudioSession()
            }
        }
        state = .off
    }

    /// Rebuilds everything after the engine stopped on its own. If that fails the loop stays
    /// off, which `state` shows.
    private func restart() {
        tearDown(deactivatingSession: false)
        Task { try? await start() }
    }

    // MARK: - Audio session

    private static func activateAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true)
        #endif
    }

    private static func deactivateAudioSession() {
        #if os(iOS)
        // Lets other apps' audio resume. It fails only if the session is already inactive
        // (after an interruption) or still busy, and there is nothing more to do either way.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func observeInterruptions() {
        #if os(iOS)
        let interruptions = NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification)
            .map { InterruptionEvent($0) }
        Task { [weak self] in
            for await event in interruptions {
                guard let self else { return }
                self.handleInterruption(event)
            }
        }
        #endif
    }

    #if os(iOS)
    private func handleInterruption(_ event: InterruptionEvent?) {
        switch event {
        case .began:
            // iOS has already stopped the engine and deactivated the session. Restart from
            // scratch when it's over. A start in progress (say, a restart) is abandoned.
            guard pipeline != nil || isStarting else { return }
            tearDown(deactivatingSession: false)
            resumeAfterInterruption = true
        case .ended(let shouldResume):
            guard resumeAfterInterruption else { return }
            resumeAfterInterruption = false
            // If iOS doesn't allow resuming, or starting fails, the loop stays off.
            guard shouldResume else { return }
            Task { try? await start() }
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
        let playback = SpeechPlayback(player: pipeline.player, format: pipeline.speechFormat) { [weak self] playback in
            Task { @MainActor in self?.speechFinished(playback) }
        }
        currentSpeech = playback
        state = .speaking
        synthesizer.write(utterance) { @Sendable buffer in
            playback.receive(buffer)
        }
        pipeline.player.play()
    }

    private func speechFinished(_ playback: SpeechPlayback) {
        guard currentSpeech === playback else { return }
        currentSpeech = nil
        updateListeningState()
        speakNextIfIdle()
    }

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
    case notImplemented
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
