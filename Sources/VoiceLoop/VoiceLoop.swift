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
/// there, not pitch-shifted: taps when listening starts and stops, low taps once each time
/// `isAgentWorking` turns on (only with echo cancellation on), and whatever `play(_:)` is asked
/// for.
///
/// With `isPushToTalk` on, all of that keeps running, but the microphone is muted except while
/// a button is held (`beginTalking()` to `endTalking()`), and what was said during the hold is
/// sent once it is released, rather than at a pause.
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
    /// `stop()`, after the audio input or output device changes (AirPods connecting or taken
    /// out; it plays the stop cue and doesn't start again), and after an unrecoverable failure
    /// (a failed `start()`, a transcriber failure, an audio interruption iOS doesn't let it
    /// resume from, or the engine stopping itself more than 3 times in 10 seconds). While the
    /// engine is rebuilt after it stopped itself and couldn't start again, and during an audio
    /// interruption, it stays `.listening(partial: "")`. iOS doesn't promise to report an interruption's end, so the
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
                loadKokoroModelIfChosen()
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
    /// While the Kokoro model is `.loading` or `.downloading`, the stage its load has reached and
    /// when it got there. Nil until the load reports a stage, and while no load is under way.
    public var kokoroLoadStage: (stage: KokoroLoadStage, since: Date)? {
        kokoroModel.loadStage
    }
    /// Which Kokoro model speaks the Kokoro voices, or nil for none: then no download starts, and
    /// the best system voice speaks for a Kokoro voice. Choosing another while a Kokoro voice is
    /// chosen loads it in place of the one loaded, downloading it the first time, and until it is
    /// ready the best system voice speaks. Choosing none frees the loaded one; a download under
    /// way isn't cancelled, and its model is freed once it finishes.
    public var kokoroModelVariant: KokoroModelVariant? {
        get { kokoroModel.variant }
        set { kokoroModel.variant = newValue }
    }
    /// The Kokoro model until another is chosen.
    public static let defaultKokoroModelVariant = KokoroModelVariant.soniqo5s
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
    /// Words said differently: each is replaced in a message as it is queued (see
    /// `Pronunciation`), before Kokoro's numbers and acronyms are spelled out. A respelling is
    /// said by every voice. A phonetic pronunciation's word is replaced by placeholders that the
    /// Kokoro voices say with its phonemes, and that the system voices say as the word. Either
    /// way, a message keeps what it was queued with.
    public var pronunciations: [Pronunciation] = [] {
        didSet {
            guard pronunciations != oldValue else { return }
            phoneticPlaceholders.add(pronunciations)
            pronunciationReplacer = PronunciationReplacer(pronunciations, placeholders: phoneticPlaceholders)
        }
    }
    @ObservationIgnored private var pronunciationReplacer = PronunciationReplacer([])
    /// The placeholders of every word and phonemes of a phonetic pronunciation or a
    /// `preview(word:phonemes:)` this run. None is forgotten, so a message queued before its
    /// pronunciation changed still says what it was queued with.
    @ObservationIgnored private var phoneticPlaceholders = PhoneticPlaceholders()
    /// While speaking, transcripts with fewer words than this are ignored instead of
    /// interrupting. Raise it if the app's own voice leaks through echo cancellation. Without
    /// echo cancellation (if it couldn't start), speech never interrupts a reply.
    public var bargeInMinimumWords = 1
    /// Push-to-talk: the microphone is muted except while the push-to-talk button is held, from
    /// `beginTalking()` to `endTalking()`, and what was said during a hold is sent as one
    /// utterance after the release, never at a pause. The engine and the recognizer run on as
    /// in hands-free mode, fed silence of the same length while the microphone is muted, so a
    /// press needs no start-up time, and the recognizer still reports a hold's last words after
    /// the release. Replies are spoken as they come, except during a hold and until its
    /// utterance is sent; a press stops the reply being spoken and drops the queue, and nothing
    /// heard interrupts a reply.
    ///
    /// Turning it on drops the utterance in progress. Turning it off ends any hold and listens
    /// hands-free again: what the hold heard so far is sent after a pause, as any utterance in
    /// progress is.
    public var isPushToTalk = false {
        didSet {
            guard isPushToTalk != oldValue else { return }
            pushToTalkChanged()
        }
    }
    /// Whether the push-to-talk button is held: from `beginTalking()` to `endTalking()`.
    public private(set) var isTalking = false
    /// Whether `beginTalking()` would start a hold: push-to-talk is on, and the loop is
    /// listening. Not while it is off, starting, or rebuilding its engine, when the start cue
    /// couldn't play and what was said would be lost.
    public var canTalk: Bool {
        access(keyPath: \.canTalk)
        return isPushToTalk && pipeline != nil
    }
    /// Whether the microphone is muted from the AirPods: while voice mode runs, a press of the
    /// stem (the Digital Crown on AirPods Max) mutes or unmutes it. iOS mutes the input itself,
    /// with its own chime; on macOS the loop mutes it, through `microphoneGate`. Either way the
    /// stop cue plays on mute and the start cue on unmute. What was said before a mute is sent
    /// after the pause, as usual. Stopping voice mode unmutes it.
    ///
    /// The system makes the press a mute only during a call, so voice mode also takes it as a
    /// media remote command (play, pause or play/pause), which mutes or unmutes it the same way.
    /// See `installRemoteCommands()`.
    public private(set) var isInputMuted = false
    /// Follows the AirPods mute while voice mode runs (see `isInputMuted`). Nil while it is off.
    @ObservationIgnored private var inputMuteObserver: Task<Void, Never>?
    /// Takes the media remote commands while voice mode runs (see `installRemoteCommands()`).
    /// Nil while it is off, and in tests that don't set `VoiceEnvironment.makeNowPlaying`.
    @ObservationIgnored private var nowPlaying: (any NowPlaying)?
    /// Called when voice mode ends because the audio input or output device changed, such as
    /// AirPods connecting or being taken out, right after `state` turns `.off`, so the app can
    /// leave voice mode as if Adam had. Not called for any other stop. Voice mode doesn't start
    /// again on its own, and plays the stop cue on the new devices, with push-to-talk too.
    @ObservationIgnored public var onStoppedForDeviceChange: (@MainActor () -> Void)?
    #if os(macOS)
    /// The default input and output at voice mode's first start, kept through rebuilds: voice
    /// mode ends when they are no longer these. Nil while it is off. iOS has none: each route
    /// change carries its own routes.
    @ObservationIgnored private var deviceBaseline: AudioDevices?
    #endif
    /// Follows the audio session's route changes while voice mode runs. Nil while it is off, so a
    /// start that finds it set is a rebuild.
    @ObservationIgnored private var routeChangeObserver: Task<Void, Never>?
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
    /// Whether `play(_:)`, the start and stop of listening, and the working cue make a sound.
    /// Most tests turn it off, since they measure what was spoken by how much sound came out.
    @ObservationIgnored package var playsSoundCues = true
    /// Whether the bot is working on a reply, for the app to set while it shows the bot typing.
    /// Each time it turns on, the loop plays `SoundCue.agentWorking`, three low taps, once, so
    /// Adam hears that a reply is on its way without looking. They never sound with a reply: if
    /// one is being said, the taps wait until its sound has ended, and one that starts while they
    /// play cuts them off, to play again in full after it if the bot is still working. They also
    /// wait while the loop is off, starting, or rebuilding its engine. They play through the
    /// loop's engine, so echo cancellation takes them out of what the microphone hears, and only
    /// with echo cancellation on: without it, the microphone would hear them as loud as they
    /// play, and the recognizer and the pause detector would take them for Adam talking.
    public var isAgentWorking = false {
        didSet {
            guard isAgentWorking != oldValue else { return }
            if !isAgentWorking {
                hasPlayedWorkingCue = false
            }
            updateWorkingCue()
        }
    }
    /// Whether `SoundCue.agentWorking` has played since `isAgentWorking` last turned on. A play
    /// that was cut off before it finished, by a reply or by the engine stopping, doesn't count.
    @ObservationIgnored package private(set) var hasPlayedWorkingCue = false
    /// Whether a reply was cut off with the pitch shift on, and neither another reply nor the
    /// working cue has played since: see `workingCueLeadIn`.
    @ObservationIgnored private var shiftedReplyWasCutOff = false

    /// How long the working taps would wait before starting if they played now, in seconds. A
    /// reply that has just ended or been cut off can still be on its way out of the pitch shift,
    /// which keeps sounding as it empties, and offline it holds a render pass of it (see
    /// `SpeechOutput.completion`): `SpeechOutput.pitchShiftTail`. A shifted reply cut off
    /// mid-sound runs on longer, so the taps after one wait `SpeechOutput.cutOffPitchShiftTail`.
    package var workingCueLeadIn: Double {
        shiftedReplyWasCutOff ? SpeechOutput.cutOffPitchShiftTail : SpeechOutput.pitchShiftTail
    }

    /// One element per finished utterance. Iterate it from one long-lived task (for example
    /// the app model): it has a single consumer, and cancelling that iteration ends the
    /// stream for good.
    @ObservationIgnored public let utterances: AsyncStream<Utterance>
    @ObservationIgnored private let utteranceContinuation: AsyncStream<Utterance>.Continuation

    /// The running engine and analyzer. Nil while off, while starting, and during a rebuild
    /// or an interruption (when `state` is still `.listening`).
    @ObservationIgnored private var pipeline: Pipeline? {
        didSet {
            guard (oldValue == nil) != (pipeline == nil) else { return }
            withMutation(keyPath: \.canTalk) {}
        }
    }
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
    /// Push-to-talk's mute on the microphone, shared with each pipeline's tap.
    @ObservationIgnored private let microphoneGate = MicrophoneGate()

    /// A push-to-talk hold that has been released, until its utterance is sent.
    private struct Release {
        /// When the button was released.
        let started: ContinuousClock.Instant
        /// Where the hold ended on the analyzer's timeline, once the microphone tap has reached it.
        var end: CMTime?
        /// Asks the recognizer to finalize the audio through `end`.
        var finalizing: Task<Void, Never>?
        /// When the recognizer finished finalizing the audio through `end`.
        var finalized: ContinuousClock.Instant?
        /// The end of the latest result handled since the release, on the analyzer's timeline.
        var heardThrough: CMTime?
    }

    /// The hold last released, until its utterance is sent. Nil otherwise.
    @ObservationIgnored private var release: Release?

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
        // Removed by `tearDown(.stop)`, which a start that fails also ends in.
        observeInputMute()
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
        // A rebuild (an engine that couldn't restart, a settings change, or an interruption) comes
        // while the route changes are still followed from the first start.
        let isRebuild = routeChangeObserver != nil
        let devices = environment.audioDevices()
        if !isRebuild {
            observeRouteChanges()
            #if os(macOS)
            // What voice mode listens and speaks through until it stops; a rebuild keeps them, so
            // it can't take up new ones. The changes this start made itself are part of it.
            deviceBaseline = devices
            #endif
        }
        // Also after a rebuild, which has no "stopped" before it.
        Self.log.notice(
            "voice mode started",
            pipeline.formatContext.merging([
                "echoCancellation": "\(pipeline.hasVoiceProcessing)",
                "devices": devices.logDescription,
                "rebuild": "\(isRebuild)",
            ]) { $1 }
        )
        pipeline.timeline.started(
            echoCancellation: pipeline.hasVoiceProcessing,
            fastResults: recognizer.reportsFastResults,
            tapFramesRequested: Pipeline.tapBufferSize,
            analyzerRate: recognizer.audioFormat.sampleRate
        )
        pipeline.timeline.recognizerStarted(called: recognizerStart.called, returned: recognizerStart.returned)
        #if os(macOS)
        // The rebuild may have come from the default input or output changing, which can show
        // only after the engine's configuration change, with nothing to say so after.
        if isRebuild, stopIfDevicesChanged(source: "rebuild") {
            return
        }
        #endif

        let configurationChanges = NotificationCenter.default.notifications(
            named: .AVAudioEngineConfigurationChange,
            object: pipeline.engine
        )
        pipeline.tasks = [
            Task { [weak self] in
                await self?.listen(to: recognizer, in: pipeline)
            },
            Task { [weak self] in
                while true {
                    do {
                        try await Task.sleep(for: .milliseconds(100))
                    } catch {
                        // The pipeline was torn down. For a rebuild, the new start checks the
                        // devices itself.
                        return
                    }
                    #if os(macOS)
                    // The default input or output can change with no configuration change to
                    // say so, such as between two outputs of the same format.
                    if self?.stopIfDevicesChanged(source: "poll", logsUnchanged: false) == true {
                        return
                    }
                    #endif
                    self?.checkForPause()
                }
            },
            Task { [weak self, weak pipeline] in
                // The engine stops itself when the audio hardware changes. Start it again so
                // listening carries on (on the iPhone every new engine stops once right after it
                // starts), unless the devices changed: that ends voice mode.
                for await _ in configurationChanges {
                    guard let self, let pipeline, self.pipeline === pipeline else { return }
                    #if os(macOS)
                    // On the Mac a change of the default input or output can show here, in the
                    // 100 ms check above, or at the end of a rebuild. On iOS the route change
                    // says whether a device came or went (`routeChanged(_:)`).
                    if self.stopIfDevicesChanged(source: "configurationChange") {
                        return
                    }
                    #endif
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
        // is being rebuilt; the rebuild's start plays it. With push-to-talk, he can talk only
        // once he presses, which plays it then.
        if !isPushToTalk {
            play(.listeningStarted)
        }
        // Replies carried over a rebuild, or queued while starting. Does nothing if the engine
        // is being rebuilt.
        speakNextIfIdle()
        // The bot may have started working before voice mode started. After the start cue, so
        // the taps follow it, and after the reply above, so one that started makes them wait.
        updateWorkingCue()
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
            microphoneGate: microphoneGate,
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

    /// Push-to-talk's button is pressed: unmutes the microphone and plays the start cue. Like a
    /// barge-in, it stops the reply being spoken and drops the queued ones. Without echo
    /// cancellation, the microphone stays muted until the start cue has played, so the cue
    /// isn't heard as speech.
    ///
    /// Pressed again before the last hold's utterance was sent, it carries that utterance on
    /// rather than sending it early, so none of its words still to be reported are lost: both
    /// holds are sent as one utterance after this one is released. Does nothing unless
    /// `canTalk`, or while the button is already held.
    public func beginTalking() {
        guard canTalk, !isTalking else { return }
        isTalking = true
        speechQueue.removeAll()
        silence(consumingEcho: true, reason: "pushToTalk")
        var start = TimelineClock.now()
        if play(.listeningStarted), pipeline?.hasVoiceProcessing == false {
            // Without echo cancellation the microphone hears the cue as loud as it plays.
            let wait = SoundCue.listeningStarted.duration / .seconds(1) + Self.halfDuplexEchoMargin.seconds
            start += AVAudioTime.hostTime(forSeconds: wait)
        }
        // Taps that waited for the reply stopped above follow the start cue, not delay it.
        updateWorkingCue()
        microphoneGate.open(at: start)
        if release != nil {
            endRelease()
            transcript.open()
        } else {
            // Words from before the press, such as late results for earlier audio, aren't
            // part of it.
            transcript.discard()
            transcript.consume(through: pipeline?.fedAudio.time ?? .zero)
            transcript.open()
            pauseDetector.reset()
        }
        pipeline?.timeline.talkStarted()
        updateListeningState()
    }

    /// Push-to-talk's button is released: mutes the microphone at once and plays the stop cue,
    /// and asks the recognizer to finalize the audio through the release
    /// (`Recognizer.finalize(through:)`). What the hold heard is sent once the recognizer has
    /// reported it all, that is once a result reaching the release has been read and nothing in
    /// the transcript is still volatile; or `finalizeGrace` after finalizing returned, for when
    /// nothing more comes; or `releaseTimeout` after the release, whichever comes first. Until
    /// then, results are kept or dropped by their audio time, inside the hold or not, never by
    /// when they arrive, so the held words it reports after the release still count. If the loop
    /// stops or rebuilds its engine meanwhile, what has been heard is sent then. Nothing is sent
    /// if nothing was heard. Does nothing unless the button is held.
    public func endTalking() {
        guard isTalking else { return }
        isTalking = false
        microphoneGate.close(at: TimelineClock.now())
        play(.listeningStopped)
        pipeline?.timeline.talkEnded()
        if pipeline != nil {
            release = Release(started: .now)
        } else {
            // Released while the engine was being built or rebuilt, which has heard nothing.
            transcript.close(at: transcript.consumedThrough)
        }
        updateListeningState()
    }

    /// Drops the utterance in progress without sending it.
    public func discardCurrentUtterance() {
        pipeline?.timeline.utteranceDiscarded(words: transcript.wordCount)
        transcript.discard()
        pauseDetector.reset()
        updateListeningState()
        speakNextIfIdle()
    }

    /// Queues `text` to be spoken after anything already queued. Strips markdown/code first, then
    /// applies `pronunciations`.
    ///
    /// Ignored while the loop is off, except that replies still queue while a resume after an
    /// interruption is pending (a failed foreground retry shows `.off`). Also queued while it is
    /// starting or rebuilding. A message waits while an utterance is in progress, so the reply
    /// doesn't start over the user and get cut off by barge-in, and while a push-to-talk hold is
    /// held or not yet sent.
    public func speak(_ text: String) {
        guard state != .off || isStarting || resumeAfterInterruption else { return }
        enqueue(pronunciationReplacer.replaced(in: SpokenText.speakable(text)))
    }

    /// Queues `spoken`, text ready to say as it is, after anything already queued. Nothing if it
    /// is empty.
    private func enqueue(_ spoken: String) {
        guard !spoken.isEmpty else { return }
        speechQueue.append(spoken)
        speakNextIfIdle()
    }

    /// Stops speaking and clears the queue.
    public func stopSpeaking() {
        speechQueue.removeAll()
        silence(consumingEcho: true, reason: "stopped")
        updateWorkingCue()
    }

    /// Says `text` right away in the current voice, speed and pitch, for trying them in settings or
    /// hearing a message again, cutting off an earlier preview. Strips markdown/code first, then
    /// applies `pronunciations`, as `speak(_:)` does. While the loop is running it also stops any
    /// reply being spoken and drops queued ones, and it plays through the loop's engine, so echo
    /// cancellation (or half-duplex) keeps it out of the transcript. Otherwise it plays straight
    /// to the speaker on an engine of its own. Like a reply, it uses the system voice for a Kokoro
    /// voice whose model isn't ready.
    public func preview(_ text: String) {
        preview(spoken: pronunciationReplacer.replaced(in: SpokenText.speakable(text)))
    }

    /// Says `text` exactly as written, as `preview(_:)` otherwise does, for hearing a pronunciation
    /// in settings: neither markdown stripping nor `pronunciations` change it, just as nothing
    /// changes a replacement once it is in place. Otherwise a swap, such as "cat" said as "dog"
    /// and "dog" as "cat", would play the wrong word.
    public func preview(asWritten text: String) {
        preview(spoken: text)
    }

    /// Says `word` with `phonemes`, as a phonetic `Pronunciation` would have it, saved or not, as
    /// `preview(asWritten:)` otherwise does: for hearing a phonetic pronunciation in settings. A
    /// Kokoro voice whose model is ready says the phonemes; any other voice says the word as
    /// written. Both are trimmed; nothing when either is blank.
    public func preview(word: String, phonemes: String) {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let phonemes = phonemes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !phonemes.isEmpty else { return }
        preview(spoken: phoneticPlaceholders.add(word: word, phonemes: phonemes))
    }

    /// Whether `preview(word:phonemes:)` says the phonemes: a Kokoro voice is chosen and its model
    /// is ready. Otherwise it says the word as written, whatever the phonemes.
    public var saysPhonemes: Bool {
        readyKokoroVoice() != nil
    }

    /// The phoneme symbols the Kokoro voices can say now, for checking suggested phonemes: while
    /// the model is ready, those in its vocabulary, read as it loaded; otherwise, or if it couldn't
    /// be read, misaki's American English symbols, which Kokoro's dictionaries use. Observable: it
    /// changes as the model loads and is freed.
    public var kokoroPhonemeSymbols: Set<Character> {
        guard kokoroModel.state == .ready, !kokoroModel.phonemeSymbols.isEmpty else {
            return MisakiPhonemes.usSymbols
        }
        return kokoroModel.phonemeSymbols
    }

    /// Says `text`, ready to say as it is, for `preview(_:)`, `preview(asWritten:)` and
    /// `preview(word:phonemes:)`.
    private func preview(spoken text: String) {
        stopPreviewPlayer()
        // Starting or rebuilding counts as running: speech queues for the engine then, and
        // a preview played outside it would reach the microphone and be sent as speech.
        if state != .off || isStarting {
            logPreviewStarted(throughLoop: true)
            // As `stopSpeaking()` does, except that the working cue waits to see whether the
            // preview plays: if it does, the cue waits for it to end.
            speechQueue.removeAll()
            silence(consumingEcho: true, reason: "stopped")
            enqueue(text)
            updateWorkingCue()
            return
        }
        guard !text.isEmpty else { return }
        let playback: SpeechPlayback
        do {
            playback = try previewPlayer.play(pitch: speechPitch)
        } catch {
            Self.log.error("voice preview failed to start", error.logContext())
            return
        }
        logPreviewStarted(throughLoop: false)
        if let voice = readyKokoroVoice() {
            previewKokoroSynthesis = synthesizeWithKokoro(text, voice: voice, into: playback) { [self] rest in
                previewWithSystemVoice(rest, into: playback)
            }
        } else {
            previewWithSystemVoice(text, into: playback)
        }
    }

    /// Logs the voice, speed and pitch a preview is about to play with. `throughLoop` says it
    /// plays through the running loop's engine rather than one of its own. No text: it can
    /// hold the user's words.
    private func logPreviewStarted(throughLoop: Bool) {
        let kokoroVoice = readyKokoroVoice()
        Self.log.info("voice preview started", [
            "voice": voiceIdentifier ?? "default",
            "engine": kokoroVoice == nil ? "system" : "kokoro",
            "kokoroModel": kokoroModelVariant?.rawValue ?? "none",
            "speechRate": speechRate,
            "kokoroSpeed": KokoroSpeed.speed(forRate: speechRate),
            "speechPitch": speechPitch,
            "throughLoop": throughLoop,
        ])
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
    /// engine. A cue still playing finishes first. Returns whether it plays.
    @discardableResult
    public func play(_ cue: SoundCue) -> Bool {
        guard playsSoundCues, let pipeline, pipeline.engine.isRunning else { return false }
        lastCueID += 1
        let id = lastCueID
        unfinishedCues.append((id, cue))
        // The working cue starts once the reply before it is out of the pitch shift.
        let leadIn = cue == .agentWorking ? workingCueLeadIn : 0
        if cue == .agentWorking {
            shiftedReplyWasCutOff = false
        }
        pipeline.play(cue, leadIn: leadIn) { [weak self] in
            Task { @MainActor in self?.cueFinished(id) }
        }
        return true
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

    /// Deletes every stored Kokoro model now, for settings. With a Kokoro voice and a model chosen,
    /// that model then downloads again, fresh, and until it is ready the best system voice speaks.
    /// Set `kokoroModelVariant` to nil first for nothing to download.
    public func deleteKokoroModels() {
        kokoroModel.removeStoredModels()
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
        guard isPushToTalk else {
            apply(piece)
            return
        }
        noteHoldEnd()
        if let release {
            self.release?.heardThrough = max(release.heardThrough ?? piece.range.end, piece.range.end)
        }
        apply(piece)
        sendHeldUtteranceIfReported()
    }

    /// Adds a result to the transcript, interrupting a reply if it is a barge-in.
    private func apply(_ piece: TranscriptPiece) {
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
            updateWorkingCue()
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
        if isPushToTalk {
            // A hold is sent once released and reported, never at a pause.
            noteHoldEnd()
            if let release, let finalized = release.finalized, finalized.duration(to: .now) >= Self.finalizeGrace {
                sendHeldUtterance(trigger: "finalized")
            } else if let release, release.started.duration(to: .now) >= Self.releaseTimeout {
                sendHeldUtterance(trigger: "timeout")
            }
            return
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

    // MARK: - Push-to-talk

    /// The longest a released hold waits for the recognizer to report it before it is sent with
    /// what has been heard. The recognizer has been measured to report a word up to 3.8 s after
    /// it was spoken (docs/research/voice-barge-in-latency.md), so a hold's last words are in by
    /// then even if finalizing fails.
    private static let releaseTimeout: Duration = .seconds(4)

    /// How long after finalizing returned a released hold waits for its results to be reported,
    /// before it is sent with what has been heard. Finalizing publishes its results before it
    /// returns, but the listening task may read them later; this is the fallback for when no
    /// result reaching the release comes, or the volatile text never turns final.
    private static let finalizeGrace: Duration = .milliseconds(500)

    private func pushToTalkChanged() {
        Self.log.notice("push to talk changed", ["on": isPushToTalk])
        microphoneGate.setEnabled(isPushToTalk)
        isTalking = false
        endRelease()
        if isPushToTalk {
            // Nothing said before is sent, and nothing more is kept until a hold.
            let fed = pipeline?.fedAudio.time ?? .zero
            transcript.discard()
            transcript.consume(through: fed)
            transcript.close(at: fed)
            pauseDetector.reset()
        } else {
            transcript.open()
        }
        updateListeningState()
        speakNextIfIdle()
    }

    /// Once the microphone tap has reached the released hold's end: closes the transcript there,
    /// so only words from inside the hold are kept, and asks the recognizer to finalize the audio
    /// through it.
    private func noteHoldEnd() {
        guard var release, release.end == nil, let end = microphoneGate.takeHeldThrough() else { return }
        release.end = end
        transcript.close(at: end)
        if let recognizer = pipeline?.recognizer {
            release.finalizing = Task { [weak self] in
                do {
                    try await recognizer.finalize(through: end)
                } catch {
                    // The release waits for a final result or `releaseTimeout` instead.
                    if !Task.isCancelled {
                        Self.log.warning("finalizing a push-to-talk hold failed", error.logContext())
                    }
                    return
                }
                guard !Task.isCancelled else { return }
                // Its results may not have been read yet: they send it when they are, or the
                // pause check does after `finalizeGrace`.
                self?.release?.finalized = .now
                self?.sendHeldUtteranceIfReported()
            }
        }
        self.release = release
    }

    /// Sends the released hold's utterance if the recognizer has reported all of it: a result
    /// reaching the hold's end has been read, and nothing in the transcript is still volatile.
    /// Results come in the order of their audio, so every final result for the hold has been
    /// read by then, however late it came.
    private func sendHeldUtteranceIfReported() {
        guard let release, let end = release.end, let heard = release.heardThrough,
              heard >= end, !transcript.hasVolatileText else { return }
        sendHeldUtterance(trigger: "reported")
    }

    /// Sends what the released hold heard, if anything, and listens on: a reply waiting for it
    /// can play. `trigger` says what decided it, for the timeline log.
    private func sendHeldUtterance(trigger: String) {
        yieldHeldUtterance(trigger: trigger)
        pauseDetector.reset()
        updateListeningState()
        speakNextIfIdle()
    }

    /// Sends what the released hold heard, if anything, and keeps nothing more until the next
    /// hold: what the recognizer reports later for the hold's audio is dropped, as for any
    /// utterance sent. Nothing else: `tearDown` uses it too.
    private func yieldHeldUtterance(trigger: String) {
        guard let release else { return }
        endRelease()
        let words = transcript.wordCount
        let utterance = transcript.take()
        // Timed out before the tap reached the end: everything fed so far was the hold's.
        let end = release.end ?? pipeline?.fedAudio.time ?? .zero
        transcript.consume(through: end)
        transcript.close(at: end)
        if !utterance.text.isEmpty {
            pipeline?.timeline.utteranceSent(
                words: words,
                lastVoice: pauseDetector.lastVoice,
                lastChange: pauseDetector.lastChange,
                endsSentence: PauseDetector.endsSentence(utterance.text),
                release: (started: release.started, trigger: trigger)
            )
            utteranceContinuation.yield(utterance)
        }
    }

    /// Forgets the released hold, if any, and stops finalizing it.
    private func endRelease() {
        release?.finalizing?.cancel()
        release = nil
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

    /// `playingStopCue` false leaves the stop cue out of a stop, for a caller that plays it
    /// another way.
    private func tearDown(_ kind: Teardown, playingStopCue: Bool = true) {
        runID += 1
        if kind == .rebuild, let currentSpeech {
            speechQueue.insert(currentSpeech.text, at: 0)
        }
        silence(consumingEcho: true, reason: "teardown")
        // Its engine goes, and with it whatever the shift was still holding.
        shiftedReplyWasCutOff = false
        if kind == .stop {
            speechQueue.removeAll()
            // A hold ends with voice mode. Through a rebuild it carries on.
            isTalking = false
            microphoneGate.endHold()
        }
        // Adam let go meaning to send it, so a released hold's utterance is sent with what has
        // been heard so far. A hold still held goes with the transcript, as an utterance in
        // progress does.
        yieldHeldUtterance(trigger: "teardown")
        transcript = Transcript()
        if isPushToTalk && !isTalking {
            // Nothing is kept until the next hold.
            transcript.close(at: .zero)
        }
        pauseDetector.reset()
        // A cue cut off here isn't played again; the next start plays its own.
        unfinishedCues = []
        if let pipeline {
            self.pipeline = nil
            // No stop cue for a rebuild, for an engine that has stopped (an interruption, or one
            // that keeps stopping), with push-to-talk, where it marks a release, or for a change
            // of devices, which plays it on an engine of its own.
            if kind == .stop && playingStopCue && playsSoundCues && pipeline.engine.isRunning && !isPushToTalk {
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
            stopObservingInputMute()
            stopObservingRouteChanges()
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
        // A player the engine stopped under still says it is playing, and never plays what is
        // scheduled on it next: the next reply would be silent, and never finish. `silence`
        // stops the speech player only for a reply in progress, and one that played to its end
        // leaves it playing.
        pipeline.speech.player.stop()
        // Working taps that were cut off play again as the others do, but only once nothing is
        // said: the reply cut off with them starts over first.
        if interruptedCues.contains(.agentWorking) {
            hasPlayedWorkingCue = false
        }
        do {
            try pipeline.restartEngine()
            Self.log.notice("audio engine restarted", pipeline.formatContext)
            for cue in interruptedCues where cue != .agentWorking {
                play(cue)
            }
            speakNextIfIdle()
            // Taps that waited for the engine, or for the reply it cut off. Not during a start,
            // which plays them itself, after its start cue.
            if !isStarting {
                updateWorkingCue()
            }
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

    // MARK: - AirPods mute

    /// For the mute logs.
    private nonisolated static var platform: String {
        #if os(macOS)
        "macOS"
        #else
        "iOS"
        #endif
    }

    /// Starts following the AirPods mute (see `isInputMuted`), unless it is already followed.
    private func observeInputMute() {
        guard inputMuteObserver == nil else { return }
        let changes = NotificationCenter.default.notifications(named: AVAudioApplication.inputMuteStateChangeNotification)
            .compactMap { $0.userInfo?[AVAudioApplication.muteStateKey] as? Bool }
        inputMuteObserver = Task { [weak self] in
            for await isMuted in changes {
                guard let self, !Task.isCancelled else { return }
                self.inputMuteChanged(isMuted)
            }
        }
        Self.log.notice("input mute observer installed", ["platform": Self.platform])
        #if os(macOS)
        // On macOS the app does the muting itself. The handler can run on any thread.
        let gate = microphoneGate
        do {
            try AVAudioApplication.shared.setInputMuteStateChangeHandler { @Sendable isMuted in
                VoiceLoop.log.notice("input mute handler called", ["muted": isMuted, "platform": VoiceLoop.platform])
                gate.setMuted(isMuted)
                return true
            }
            Self.log.notice("input mute handler installed", ["platform": Self.platform])
        } catch {
            Self.log.error("input mute handler failed to install", error.logContext())
        }
        #endif
        installRemoteCommands()
    }

    /// Stops following the AirPods mute, and unmutes the microphone, when voice mode stops.
    private func stopObservingInputMute() {
        guard let inputMuteObserver else { return }
        inputMuteObserver.cancel()
        self.inputMuteObserver = nil
        // Before the handler goes, so on macOS it unmutes the gate too.
        if AVAudioApplication.shared.isInputMuted {
            do {
                try AVAudioApplication.shared.setInputMuted(false)
                Self.log.notice("input unmuted as voice mode stops", ["platform": Self.platform])
            } catch {
                Self.log.warning("unmuting the input failed", error.logContext())
            }
        }
        #if os(macOS)
        do {
            try AVAudioApplication.shared.setInputMuteStateChangeHandler(nil)
            Self.log.notice("input mute handler removed", ["platform": Self.platform])
        } catch {
            Self.log.error("input mute handler failed to remove", error.logContext())
        }
        #endif
        microphoneGate.setMuted(false)
        isInputMuted = false
        if let nowPlaying {
            nowPlaying.remove()
            self.nowPlaying = nil
            Self.log.notice("remote commands removed", ["platform": Self.platform])
        }
        Self.log.notice("input mute observer removed", ["platform": Self.platform])
    }

    /// The AirPods mute changed: shows it, and plays the stop cue on mute and the start cue on
    /// unmute. On macOS the handler has muted or unmuted `microphoneGate` already.
    private func inputMuteChanged(_ isMuted: Bool) {
        Self.log.notice("input mute changed", ["muted": isMuted, "platform": Self.platform])
        guard isMuted != isInputMuted else { return }
        isInputMuted = isMuted
        nowPlaying?.setMuted(isMuted)
        play(isMuted ? .listeningStopped : .listeningStarted)
    }

    /// Takes a press of the AirPods stem as a media remote command too, while voice mode runs.
    /// The system makes the press the input mute gesture above only during a call (a CallKit
    /// call on iOS); otherwise a press may come to the Now Playing app as play, pause or
    /// play/pause. Each of them toggles the mute (`toggleInputMute()`). Voice mode shows as
    /// playing, and as paused while muted, so the press after a mute may come as play.
    ///
    /// What can keep the commands from coming (from Apple's guidance; only a device can tell):
    /// - iOS sends them only to the Now Playing app, and a session that mixes with other audio
    ///   can't be it. `activateAudioSession` sets `.mixWithOthers` while `pausesOtherAudio` is
    ///   off ("Pause Other Audio" in the app's settings), so that must be on.
    /// - The Now Playing app is one that has started playing audio; voice mode's start cue does.
    /// - With the microphone in use the AirPods are on HFP, and their press may then go out as
    ///   a call control, which only a CallKit call receives, rather than as a media command.
    /// - On macOS the Now Playing app is chosen by `MPNowPlayingInfoCenter.playbackState`.
    private func installRemoteCommands() {
        guard let nowPlaying = environment.makeNowPlaying?() else { return }
        nowPlaying.install(isMuted: isInputMuted) { [weak self] command in
            self?.remoteCommandReceived(command)
        }
        self.nowPlaying = nowPlaying
        Self.log.notice("remote commands installed", ["platform": Self.platform, "pausesOtherAudio": pausesOtherAudio])
    }

    /// A press of the AirPods stem came as a media remote command: toggles the mute.
    private func remoteCommandReceived(_ command: RemoteCommand) {
        Self.log.notice("remote command received", ["command": command.rawValue, "muted": isInputMuted, "platform": Self.platform])
        // Voice mode may have stopped since the press.
        guard nowPlaying != nil else { return }
        toggleInputMute()
        Self.log.notice("remote command handled", ["command": command.rawValue, "muted": isInputMuted, "platform": Self.platform])
    }

    /// Mutes the microphone, or unmutes it if muted, as the AirPods mute gesture would: through
    /// `AVAudioApplication`, which mutes the input on iOS and calls the mute handler, which mutes
    /// `microphoneGate`, on macOS. Shows the change and plays its cue at once, since the mute
    /// notification may come late or not at all (iOS sends it only while the session records);
    /// when it comes, it finds nothing changed, so the cue plays once.
    private func toggleInputMute() {
        let muted = !isInputMuted
        do {
            try environment.setInputMuted(muted)
        } catch {
            Self.log.warning("toggling the input mute failed", error.logContext(["muted": "\(muted)", "platform": Self.platform]))
            return
        }
        inputMuteChanged(muted)
    }

    // MARK: - Audio devices

    /// Starts following the audio session's route changes for `routeChanged(_:)`.
    private func observeRouteChanges() {
        let changes = environment.audioRouteChanges()
        routeChangeObserver = Task { [weak self] in
            for await change in changes {
                guard let self, !Task.isCancelled else { return }
                self.routeChanged(change)
            }
        }
    }

    /// Stops following the route changes, and on the Mac forgets the devices voice mode started
    /// with, when it stops.
    private func stopObservingRouteChanges() {
        routeChangeObserver?.cancel()
        routeChangeObserver = nil
        #if os(macOS)
        deviceBaseline = nil
        #endif
    }

    /// An iOS route change: voice mode ends if a device came or went and the route's devices
    /// differ on the two sides of the change. Any other reason, such as the app's own category
    /// change or speaker override, or the route settling after the start, is ignored. Each
    /// change carries its own routes, read as it was posted, so one handled late can't hide
    /// another.
    private func routeChanged(_ change: AudioRouteChange) {
        let stops = change.isDeviceChange && change.previous != change.current
        Self.log.notice("audio route changed", [
            "reason": change.reason,
            "before": change.previous.logDescription,
            "after": change.current.logDescription,
            "action": stops ? "stopVoiceMode" : change.isDeviceChange ? "keepListening" : "ignore",
        ])
        if stops {
            stopForDeviceChange()
        }
    }

    #if os(macOS)
    /// Ends voice mode if the default input or output is no longer the one in `deviceBaseline`,
    /// and returns whether it did. `source` says what asked, for the logs. A check that finds
    /// nothing changed is logged only with `logsUnchanged`.
    private func stopIfDevicesChanged(source: String, logsUnchanged: Bool = true) -> Bool {
        guard let baseline = deviceBaseline else { return false }
        let current = environment.audioDevices()
        let changed = current != baseline
        if changed || logsUnchanged {
            Self.log.notice("audio devices checked", [
                "source": source,
                "before": baseline.logDescription,
                "after": current.logDescription,
                "action": changed ? "stopVoiceMode" : "keepListening",
            ])
        }
        guard changed else { return false }
        stopForDeviceChange()
        return true
    }
    #endif

    /// Ends voice mode because the audio devices changed, as when AirPods connect or are taken
    /// out. It doesn't start again, and tells the app (`onStoppedForDeviceChange`). The stop cue
    /// plays once the loop's engine is gone, on one of its own that only plays, so it reaches
    /// whatever output is current now, without the microphone, and with push-to-talk too.
    private func stopForDeviceChange() {
        tearDown(.stop, playingStopCue: false)
        onStoppedForDeviceChange?()
        if playsSoundCues {
            do {
                try previewPlayer.play(.listeningStopped)
            } catch {
                Self.log.warning("the stop cue failed to play after the audio devices changed", error.logContext())
            }
        }
    }

    // MARK: - Speaking

    /// Starts the next reply in the queue, unless one is playing, an utterance is in progress, or
    /// a push-to-talk hold is held or not yet sent.
    private func speakNextIfIdle() {
        guard let pipeline, pipeline.engine.isRunning, currentSpeech == nil, transcript.isEmpty,
              !isTalking, release == nil, !speechQueue.isEmpty else { return }
        let text = speechQueue.removeFirst()
        cutOffWorkingCue(on: pipeline)
        // Each message takes the pitch as it is now, also on a new or restarted engine.
        pipeline.speech.setPitch(speechPitch)
        let playback = pipeline.speech.makePlayback(text: text) { [weak self] playback in
            Task { @MainActor in self?.speechFinished(playback) }
        }
        currentSpeech = playback
        // Taps after this reply follow how it ends, not how the one before did.
        shiftedReplyWasCutOff = false
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
    /// each sentence is fed to `playback` once it's ready. Each sentence's placeholders go to
    /// Kokoro with their phonemes. Cancelling the returned task stops it: no further sentence is
    /// rendered, and the caller cancels `playback` too, so the one rendering then is dropped. If
    /// rendering fails, or the model is freed because another voice was chosen, `systemVoice` is
    /// handed the rest of the text to say, placeholders and all.
    private func synthesizeWithKokoro(
        _ text: String,
        voice: String,
        into playback: SpeechPlayback,
        systemVoice: @escaping @MainActor (String) -> Void
    ) -> Task<Void, Never> {
        let sentences = KokoroText.sentences(in: text)
        let speed = KokoroSpeed.speed(forRate: speechRate)
        let engine = kokoroModel.engine
        let acronyms = KokoroAcronyms(dictionaryWords: kokoroModel.dictionaryWords)
        return Task {
            // Kokoro can't pronounce digits, or acronyms its dictionary doesn't have. Only its
            // text is changed: the system voice gets the sentences as written.
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
                    // Numbers first: their rules read the words around them as written. Both
                    // leave placeholders as they are.
                    let spoken = acronyms.spelledOut(numbers.spelledOut(sentence))
                    // Read as the sentence starts: placeholders are only ever added, never
                    // changed, so those queued with it are all there.
                    samples = try await engine.synthesize(
                        spoken,
                        voice: voice,
                        speed: speed,
                        pronunciations: phoneticPlaceholders.phonemes(in: spoken)
                    )
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
        guard isKokoroVoiceChosen, let voiceIdentifier,
              let voice = KokoroCatalog.kokoroVoice(forOptionID: voiceIdentifier) else { return }
        kokoroModel.voice = voice
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
        // With no reply after it, taps that waited for this one play now.
        updateWorkingCue()
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
        shiftedReplyWasCutOff = pipeline.map { !$0.speech.pitchShift.bypass } ?? false
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

    /// `text` in the chosen voice and speed, for the system voice: every system voice utterance is
    /// made here. Phonetic pronunciations are for Kokoro, so each placeholder is said as its word.
    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let written = phoneticPlaceholders.written(text)
        environment.systemVoiceWillSay(written)
        let utterance = AVSpeechUtterance(string: written)
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

    // MARK: - Working cue

    /// Plays `SoundCue.agentWorking` if `isAgentWorking` and it hasn't played since that turned
    /// on, once nothing is being said, on a running engine with echo cancellation, and with sound
    /// cues on. Call it whenever one of those may have changed while the loop listens on. Not from
    /// `silence`, which a teardown uses too: it would play the cue just before the teardown cuts
    /// it off.
    ///
    /// The taps never sound with a reply: they wait while one is said, start a moment after it
    /// ends (see `play(_:)`), and a reply that starts cuts them off (`cutOffWorkingCue(on:)`).
    private func updateWorkingCue() {
        guard isAgentWorking, !hasPlayedWorkingCue, let pipeline else { return }
        if let reason = reasonWorkingCueWaits(on: pipeline) {
            Self.log.info("working cue waits", ["reason": reason])
        } else if play(.agentWorking) {
            hasPlayedWorkingCue = true
            Self.log.info("working cue played")
        }
    }

    /// Why the working cue can't play on `pipeline` now, for the logs. Nil when it can.
    private func reasonWorkingCueWaits(on pipeline: Pipeline) -> String? {
        if currentSpeech != nil { return "speaking" }
        // A player can't play in a stopped engine.
        if !pipeline.engine.isRunning { return "engineStopped" }
        // Without echo cancellation the microphone hears it as loud as it plays, and the
        // recognizer and the pause detector would take it for Adam talking.
        if !pipeline.hasVoiceProcessing { return "noEchoCancellation" }
        if !playsSoundCues { return "soundCuesOff" }
        return nil
    }

    /// For a reply about to start: stops `SoundCue.agentWorking` at once if it is playing or
    /// waiting on the cue player, so the taps never sound with a reply. Stopping the player
    /// stops every cue on it, so the others that hadn't finished play again from the start, as
    /// after the engine stops by itself. The taps wait to play again in full once nothing is
    /// said, if the agent is still working.
    private func cutOffWorkingCue(on pipeline: Pipeline) {
        guard unfinishedCues.contains(where: { $0.cue == .agentWorking }) else { return }
        let otherCues = unfinishedCues.map(\.cue).filter { $0 != .agentWorking }
        unfinishedCues = []
        pipeline.cuePlayer.stop()
        hasPlayedWorkingCue = false
        Self.log.info("working cue cut off", ["reason": "speaking"])
        for cue in otherCues {
            play(cue)
        }
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
