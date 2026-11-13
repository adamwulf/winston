@preconcurrency import AVFoundation
import Logging
import LogSupport
import Speech

// The real permission prompts, speech model and audio hardware behind `VoiceEnvironment`.
// A test process has none of them: a permission prompt needs the app's usage strings, the
// speech model may not be installed, and there may be no audio device. So this file is the
// one part of VoiceLoop the tests don't run. Keep it to calls into the system, with no logic
// of its own.

extension VoiceEnvironment {
    /// The microphone, the on-device speech model, the audio hardware, and Kokoro with its model
    /// under Application Support.
    package static let live = VoiceEnvironment(
        requestPermissions: { try await LiveSpeech.requestPermissions() },
        makeRecognizer: { try await LiveSpeech.makeRecognizer() },
        makeEngine: { AVAudioEngine() },
        enableVoiceProcessing: { try $0.setVoiceProcessingEnabled(true) },
        kokoro: LiveKokoro(directory: URL.applicationSupportDirectory.appending(path: "Kokoro", directoryHint: .isDirectory))
    )
}

/// A `SpeechAnalyzer` running a `SpeechTranscriber`.
private struct LiveRecognizer: Recognizer {
    let transcriber: SpeechTranscriber
    let analyzer: SpeechAnalyzer
    let audioFormat: AVAudioFormat
    let reportsFastResults: Bool

    var results: any AsyncSequence<TranscriptPiece, any Error> {
        transcriber.results.map { TranscriptPiece($0) }
    }

    func start(inputs: AsyncStream<AnalyzerInput>) async throws {
        try await analyzer.start(inputSequence: inputs)
    }

    func cancel() async {
        await analyzer.cancelAndFinishNow()
    }
}

@MainActor
private enum LiveSpeech {
    static func requestPermissions() async throws {
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

    /// A recognizer for the current locale, with its model installed.
    static func makeRecognizer() async throws -> any Recognizer {
        let transcriber = try await makeTranscriber()
        guard let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceLoopError.speechModelUnavailable
        }
        return LiveRecognizer(
            transcriber: transcriber,
            analyzer: SpeechAnalyzer(modules: [transcriber]),
            audioFormat: audioFormat,
            reportsFastResults: reportingOptions.contains(.fastResults)
        )
    }

    /// `.fastResults` reports about every second of audio instead of about every four, so
    /// barge-in and the live transcript follow the speaker sooner. See
    /// docs/research/voice-barge-in-latency.md.
    private static let reportingOptions: Set<SpeechTranscriber.ReportingOption> = [
        .volatileResults, .alternativeTranscriptions, .fastResults,
    ]

    /// A transcriber for the current locale, with its model installed.
    private static func makeTranscriber() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw VoiceLoopError.speechModelUnavailable
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: reportingOptions,
            attributeOptions: [.audioTimeRange]
        )
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            VoiceLoop.log.error("speech model install failed", error.logContext())
            throw VoiceLoopError.speechModelUnavailable
        }
        return transcriber
    }
}

extension TranscriptPiece {
    init(_ result: SpeechTranscriber.Result) {
        self.init(text: result.text, alternatives: result.alternatives, range: result.range, isFinal: result.isFinal)
    }
}
