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
/// the audio hardware, and the Kokoro voices' model. None of them is available to a test, so the
/// loop takes them from here. `live` is the real thing. Tests pass a scripted recognizer, an
/// engine that renders offline and a fake Kokoro, and everything else (the loop, the pipeline,
/// speech playback) runs as it does in the app.
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

    package init(
        requestPermissions: @escaping @MainActor @Sendable () async throws -> Void,
        makeRecognizer: @escaping @MainActor @Sendable () async throws -> any Recognizer,
        makeEngine: @escaping @MainActor @Sendable () throws -> AVAudioEngine,
        enableVoiceProcessing: @escaping @MainActor @Sendable (AVAudioInputNode) throws -> Void,
        kokoro: any KokoroEngine,
        languageCode: @escaping @MainActor @Sendable () -> String
    ) {
        self.requestPermissions = requestPermissions
        self.makeRecognizer = makeRecognizer
        self.makeEngine = makeEngine
        self.enableVoiceProcessing = enableVoiceProcessing
        self.kokoro = kokoro
        self.languageCode = languageCode
    }
}
