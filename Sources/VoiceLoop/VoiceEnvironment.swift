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

    package init(
        requestPermissions: @escaping @MainActor @Sendable () async throws -> Void,
        makeRecognizer: @escaping @MainActor @Sendable () async throws -> any Recognizer,
        makeEngine: @escaping @MainActor @Sendable () throws -> AVAudioEngine,
        enableVoiceProcessing: @escaping @MainActor @Sendable (AVAudioInputNode) throws -> Void,
        kokoro: any KokoroEngine,
        languageCode: @escaping @MainActor @Sendable () -> String,
        systemVoices: @escaping @MainActor @Sendable (String) -> [VoiceOption],
        now: @escaping @MainActor @Sendable () -> Date,
        kokoroUnchosenSince: @escaping @MainActor @Sendable () -> Date?,
        setKokoroUnchosenSince: @escaping @MainActor @Sendable (Date?) -> Void
    ) {
        self.requestPermissions = requestPermissions
        self.makeRecognizer = makeRecognizer
        self.makeEngine = makeEngine
        self.enableVoiceProcessing = enableVoiceProcessing
        self.kokoro = kokoro
        self.languageCode = languageCode
        self.systemVoices = systemVoices
        self.now = now
        self.kokoroUnchosenSince = kokoroUnchosenSince
        self.setKokoroUnchosenSince = setKokoroUnchosenSince
    }
}
