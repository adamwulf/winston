@preconcurrency import AVFoundation
#if os(macOS)
import CoreAudio
#endif
import Logging
import LogSupport
import Speech

// The real permission prompts, speech model, audio hardware, clock and user defaults behind
// `VoiceEnvironment`. A test process has none of them: a permission prompt needs the app's
// usage strings, the speech model may not be installed, there may be no audio device, a test
// can't wait a day, and the app's user defaults aren't a test's to change. So this file is the
// one part of VoiceLoop the tests don't run. Keep it to calls into the system, with no logic
// of its own.

extension VoiceEnvironment {
    /// The microphone, the on-device speech model, the audio hardware, Kokoro with its model
    /// under Application Support, the system clock, and the standard user defaults.
    package static let live = VoiceEnvironment(
        requestPermissions: { try await LiveSpeech.requestPermissions() },
        makeRecognizer: { try await LiveSpeech.makeRecognizer() },
        makeEngine: { AVAudioEngine() },
        enableVoiceProcessing: { try $0.setVoiceProcessingEnabled(true) },
        audioDevices: { LiveAudioDevices.current() },
        audioDeviceChanges: { LiveAudioDevices.changes() },
        kokoro: LiveKokoro(directory: URL.applicationSupportDirectory.appending(path: "Kokoro", directoryHint: .isDirectory)),
        languageCode: { AVSpeechSynthesisVoice.currentLanguageCode() },
        systemVoices: { VoiceLoop.systemVoices(language: $0) },
        now: { Date.now },
        kokoroUnchosenSince: { UserDefaults.standard.object(forKey: kokoroUnchosenSinceKey) as? Date },
        setKokoroUnchosenSince: { UserDefaults.standard.set($0, forKey: kokoroUnchosenSinceKey) }
    )
}

/// Where `VoiceEnvironment.live` keeps `kokoroUnchosenSince` in the standard user defaults.
private let kokoroUnchosenSinceKey = "kokoroUnchosenSince"

/// The audio session's route on iOS, the system's default input and output on the Mac.
@MainActor
private enum LiveAudioDevices {
    static func current() -> AudioDevices {
        #if os(iOS)
        let route = AVAudioSession.sharedInstance().currentRoute
        func devices(_ ports: [AVAudioSessionPortDescription]) -> [AudioDevices.Device] {
            ports.map { AudioDevices.Device(id: $0.uid, kind: $0.portType.rawValue) }
        }
        return AudioDevices(inputs: devices(route.inputs), outputs: devices(route.outputs))
        #else
        AudioDevices(
            inputs: defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
            outputs: defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        )
        #endif
    }

    static func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        #if os(iOS)
        let routeChanges = NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification)
        let task = Task {
            for await _ in routeChanges {
                continuation.yield()
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        #else
        // Called on a Core Audio thread. Removing it takes the same block.
        let listener: @Sendable @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { _, _ in
            continuation.yield()
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        let selectors = [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice]
        for selector in selectors {
            var address = systemAddress(selector)
            AudioObjectAddPropertyListenerBlock(system, &address, nil, listener)
        }
        continuation.onTermination = { _ in
            for selector in selectors {
                var address = systemAddress(selector)
                AudioObjectRemovePropertyListenerBlock(system, &address, nil, listener)
            }
        }
        #endif
        return stream
    }

    #if os(macOS)
    /// The default device that `selector` names, by its device ID. None if there is none.
    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> [AudioDevices.Device] {
        var address = systemAddress(selector)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return [] }
        return [AudioDevices.Device(id: "\(device)", kind: "\(device)")]
    }

    private nonisolated static func systemAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
    #endif
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

    func finalize(through time: CMTime) async throws {
        try await analyzer.finalize(through: time)
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
