@preconcurrency import AVFoundation
import Speech

/// Speech-to-text for one listening session. In the app it is a `SpeechAnalyzer` running a
/// `SpeechTranscriber`; see `LiveVoiceEnvironment.swift`.
package protocol Recognizer: Sendable {
    /// The audio format it takes.
    var audioFormat: AVAudioFormat { get }
    /// Whether it reports with `SpeechTranscriber`'s `.fastResults` option, for the logs.
    var reportsFastResults: Bool { get }
    /// What it hears, until it is cancelled or fails.
    var results: any AsyncSequence<TranscriptPiece, any Error> { get }
    /// Starts reading microphone audio from `inputs`.
    func start(inputs: AsyncStream<AnalyzerInput>) async throws
    /// Reports the audio up to `time` (on the timeline of `inputs`) now, rather than once more
    /// audio has come: when it returns, its results for that audio are final and in `results`,
    /// though maybe not read yet. Waits until it has read that far. Throws if it is cancelled
    /// or stops first.
    func finalize(through time: CMTime) async throws
    /// Stops at once.
    func cancel() async
}

/// The system services the voice loop runs on: the permission prompts, the speech recognizer,
/// the audio hardware, the Kokoro voices' model, the language, the installed voices, the clock,
/// and the app's user defaults. A test can't have the first four, can't change the language or
/// the installed voices, can't wait a day, and mustn't touch the app's user defaults, so the
/// loop takes them from here. `live` is the real thing. Tests pass a scripted recognizer, an
/// engine that renders offline, a fake Kokoro, a clock they move by hand and a record kept in
/// memory, and everything else (the loop, the pipeline, speech playback) runs as it does in the
/// app.
package struct VoiceEnvironment: Sendable {
    /// Asks for microphone and speech permission. Throws a `VoiceLoopError` when one is missing.
    package var requestPermissions: @MainActor @Sendable () async throws -> Void
    /// A recognizer for the current locale, with its model installed. Throws
    /// `VoiceLoopError.speechModelUnavailable` when there is none.
    package var makeRecognizer: @MainActor @Sendable () async throws -> any Recognizer
    /// A new audio engine for one listening session, or for one voice preview while the loop is off.
    package var makeEngine: @MainActor @Sendable () throws -> AVAudioEngine
    /// Turns on voice processing (echo cancellation) for the engine's microphone.
    package var enableVoiceProcessing: @MainActor @Sendable (AVAudioInputNode) throws -> Void
    /// The audio devices in use now: on iOS the audio session's route, on the Mac the default
    /// input and output.
    package var audioDevices: @MainActor @Sendable () -> AudioDevices
    /// Each route change of the iOS audio session, with the route before and after it, until its
    /// iteration is cancelled. Nothing on the Mac, where voice mode watches the default input and
    /// output instead.
    package var audioRouteChanges: @MainActor @Sendable () -> AsyncStream<AudioRouteChange>
    /// Speaks with the Kokoro voices, once its model has downloaded and loaded.
    package var kokoro: any KokoroEngine
    /// The language voices are offered for, as `AVSpeechSynthesisVoice.currentLanguageCode()`
    /// gives it, such as `en-US`.
    package var languageCode: @MainActor @Sendable () -> String
    /// The installed system voices for a language code, as `VoiceLoop.systemVoices(language:)`
    /// lists them.
    package var systemVoices: @MainActor @Sendable (String) -> [VoiceOption]
    /// The time by the wall clock, which measures how long the Kokoro model has gone unused,
    /// across launches.
    package var now: @MainActor @Sendable () -> Date
    /// When the last Kokoro voice was unchosen, kept across launches. Nil while a Kokoro voice
    /// is chosen. See `VoiceLoop.removeUnusedKokoroModel()`.
    package var kokoroUnchosenSince: @MainActor @Sendable () -> Date?
    /// Saves `kokoroUnchosenSince`. Nil clears it.
    package var setKokoroUnchosenSince: @MainActor @Sendable (Date?) -> Void
    /// Told the text of each utterance the system voice is about to say. Nothing in the app;
    /// tests can't hear the system voice, so they read what it was given here.
    package var systemVoiceWillSay: @MainActor @Sendable (String) -> Void
    /// Mutes or unmutes the app's audio input, as `AVAudioApplication.setInputMuted(_:)` does:
    /// on iOS the system mutes it, and on macOS it calls the loop's mute handler. Nothing unless
    /// a test sets it, since the mute belongs to the whole process, which the tests share.
    package var setInputMuted: @MainActor @Sendable (Bool) throws -> Void
    /// The media remote commands and Now Playing info for one voice mode session, which take a
    /// press of the AirPods stem (see `VoiceLoop.isInputMuted`). Nil unless a test sets it, so
    /// the tests don't make themselves the system's Now Playing app.
    package var makeNowPlaying: (@MainActor @Sendable () -> any NowPlaying)?

    package init(
        requestPermissions: @escaping @MainActor @Sendable () async throws -> Void,
        makeRecognizer: @escaping @MainActor @Sendable () async throws -> any Recognizer,
        makeEngine: @escaping @MainActor @Sendable () throws -> AVAudioEngine,
        enableVoiceProcessing: @escaping @MainActor @Sendable (AVAudioInputNode) throws -> Void,
        audioDevices: @escaping @MainActor @Sendable () -> AudioDevices,
        audioRouteChanges: @escaping @MainActor @Sendable () -> AsyncStream<AudioRouteChange>,
        kokoro: any KokoroEngine,
        languageCode: @escaping @MainActor @Sendable () -> String,
        systemVoices: @escaping @MainActor @Sendable (String) -> [VoiceOption],
        now: @escaping @MainActor @Sendable () -> Date,
        kokoroUnchosenSince: @escaping @MainActor @Sendable () -> Date?,
        setKokoroUnchosenSince: @escaping @MainActor @Sendable (Date?) -> Void,
        systemVoiceWillSay: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        setInputMuted: @escaping @MainActor @Sendable (Bool) throws -> Void = { _ in },
        makeNowPlaying: (@MainActor @Sendable () -> any NowPlaying)? = nil
    ) {
        self.requestPermissions = requestPermissions
        self.makeRecognizer = makeRecognizer
        self.makeEngine = makeEngine
        self.enableVoiceProcessing = enableVoiceProcessing
        self.audioDevices = audioDevices
        self.audioRouteChanges = audioRouteChanges
        self.kokoro = kokoro
        self.languageCode = languageCode
        self.systemVoices = systemVoices
        self.now = now
        self.kokoroUnchosenSince = kokoroUnchosenSince
        self.setKokoroUnchosenSince = setKokoroUnchosenSince
        self.systemVoiceWillSay = systemVoiceWillSay
        self.setInputMuted = setInputMuted
        self.makeNowPlaying = makeNowPlaying
    }
}

/// A media remote command that voice mode takes as a press of the AirPods stem.
package enum RemoteCommand: String, Sendable {
    case togglePlayPause
    case play
    case pause
}

/// One media remote command as it came from the system, for the loop and its logs. The logs
/// write only how long after its times later steps came, never the times themselves
/// (`MediaDiagnostics.remoteCommandTimes`).
package struct RemoteCommandEvent: Sendable {
    /// The command's name, such as `togglePlayPause` or `nextTrack`.
    package var name: String
    /// The command voice mode acts on. Nil for one it only logs (see `NowPlaying.install`).
    package var command: RemoteCommand?
    /// `MPRemoteCommandEvent.timestamp`: when the event occurred, in seconds. Apple doesn't say
    /// on what clock; like `UIEvent.timestamp`, it is likely the system uptime. The logs measure
    /// from it only if it is close to `receivedUptime` (`MediaDiagnostics.isOnUptimeClock`).
    package var timestamp: TimeInterval
    /// `ProcessInfo.systemUptime` when MediaPlayer called the handler, before it hops to the main
    /// actor.
    package var receivedUptime: TimeInterval

    package init(name: String, command: RemoteCommand?, timestamp: TimeInterval, receivedUptime: TimeInterval) {
        self.name = name
        self.command = command
        self.timestamp = timestamp
        self.receivedUptime = receivedUptime
    }
}

/// A media remote command that `NowPlaying.install` registered, for the logs.
package struct RemoteCommandRegistration: Sendable, Equatable {
    /// The command's name, such as `togglePlayPause` or `nextTrack`.
    package var name: String
    /// Whether the command is enabled, as read back after installing.
    package var isEnabled: Bool
    /// Whether voice mode acts on it (a `RemoteCommand`), rather than only logging it.
    package var isHandled: Bool

    package init(name: String, isEnabled: Bool, isHandled: Bool) {
        self.name = name
        self.isEnabled = isEnabled
        self.isHandled = isHandled
    }
}

/// The system's media remote commands and Now Playing info, for one voice mode session. In the
/// app, `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter`; see `LiveVoiceEnvironment.swift`.
@MainActor
package protocol NowPlaying: AnyObject {
    /// Starts taking the play, pause and play/pause commands, calling `handler` on the main actor
    /// with each one, and shows voice mode as Now Playing: paused while `isMuted`, playing
    /// otherwise. Every other command gets a handler too, kept disabled so the system's controls
    /// don't change, that only passes it to `handler` for the logs (its `command` is nil) and
    /// tells the system it failed. Returns every command registered.
    func install(
        isMuted: Bool,
        handler: @escaping @MainActor @Sendable (RemoteCommandEvent) -> Void
    ) -> [RemoteCommandRegistration]
    /// Shows voice mode as paused while muted, and as playing otherwise.
    func setMuted(_ isMuted: Bool)
    /// Stops taking the commands, puts back whether the logged-only ones were enabled, and clears
    /// the Now Playing info.
    func remove()
}
