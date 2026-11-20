@preconcurrency import AVFoundation
#if os(macOS)
import CoreAudio
#endif
import Logging
import LogSupport
import MediaPlayer
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
        audioRouteChanges: { LiveAudioDevices.routeChanges() },
        kokoro: LiveKokoro(directory: URL.applicationSupportDirectory.appending(path: "Kokoro", directoryHint: .isDirectory)),
        languageCode: { AVSpeechSynthesisVoice.currentLanguageCode() },
        systemVoices: { VoiceLoop.systemVoices(language: $0) },
        now: { Date.now },
        kokoroUnchosenSince: { UserDefaults.standard.object(forKey: kokoroUnchosenSinceKey) as? Date },
        setKokoroUnchosenSince: { UserDefaults.standard.set($0, forKey: kokoroUnchosenSinceKey) },
        setInputMuted: { try AVAudioApplication.shared.setInputMuted($0) },
        makeNowPlaying: { LiveNowPlaying() }
    )
}

/// Where `VoiceEnvironment.live` keeps `kokoroUnchosenSince` in the standard user defaults.
private let kokoroUnchosenSinceKey = "kokoroUnchosenSince"

/// `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter`, for `VoiceEnvironment.makeNowPlaying`.
@MainActor
private final class LiveNowPlaying: NowPlaying {
    /// The commands taken, each with the target that removes its handler, and for one that is
    /// only logged, whether it was enabled before.
    private var targets: [(command: MPRemoteCommand, target: Any, wasEnabled: Bool?)] = []

    func install(
        isMuted: Bool,
        handler: @escaping @MainActor @Sendable (RemoteCommandEvent) -> Void
    ) -> [RemoteCommandRegistration] {
        let center = MPRemoteCommandCenter.shared()
        let handled: [(MPRemoteCommand, RemoteCommand)] = [
            (center.togglePlayPauseCommand, .togglePlayPause),
            (center.playCommand, .play),
            (center.pauseCommand, .pause),
        ]
        // Every other command, only to log whether it comes. Each is disabled after its target is
        // added, so the system's controls look as they did without one.
        let logged: [(MPRemoteCommand, String)] = [
            (center.stopCommand, "stop"),
            (center.nextTrackCommand, "nextTrack"),
            (center.previousTrackCommand, "previousTrack"),
            (center.skipForwardCommand, "skipForward"),
            (center.skipBackwardCommand, "skipBackward"),
            (center.seekForwardCommand, "seekForward"),
            (center.seekBackwardCommand, "seekBackward"),
            (center.changePlaybackPositionCommand, "changePlaybackPosition"),
            (center.changePlaybackRateCommand, "changePlaybackRate"),
            (center.ratingCommand, "rating"),
            (center.likeCommand, "like"),
            (center.dislikeCommand, "dislike"),
            (center.bookmarkCommand, "bookmark"),
            (center.changeRepeatModeCommand, "changeRepeatMode"),
            (center.changeShuffleModeCommand, "changeShuffleMode"),
            (center.enableLanguageOptionCommand, "enableLanguageOption"),
            (center.disableLanguageOptionCommand, "disableLanguageOption"),
        ]
        var registrations: [RemoteCommandRegistration] = []
        for (command, name) in handled {
            command.isEnabled = true
            let target = command.addTarget { @Sendable event in
                let received = Self.received(event, name: name.rawValue, command: name)
                // MediaPlayer doesn't say which thread it calls from.
                Task { @MainActor in handler(received) }
                return .success
            }
            targets.append((command, target, nil))
            registrations.append(RemoteCommandRegistration(name: name.rawValue, isEnabled: command.isEnabled, isHandled: true))
        }
        for (command, name) in logged {
            let wasEnabled = command.isEnabled
            let target = command.addTarget { @Sendable event in
                let received = Self.received(event, name: name, command: nil)
                Task { @MainActor in handler(received) }
                // As for a command the app doesn't take.
                return .commandFailed
            }
            command.isEnabled = false
            targets.append((command, target, wasEnabled))
            registrations.append(RemoteCommandRegistration(name: name, isEnabled: command.isEnabled, isHandled: false))
        }
        setMuted(isMuted)
        return registrations
    }

    /// `event` as the loop takes it, stamped with the uptime it came at.
    private nonisolated static func received(
        _ event: MPRemoteCommandEvent,
        name: String,
        command: RemoteCommand?
    ) -> RemoteCommandEvent {
        RemoteCommandEvent(
            name: name,
            command: command,
            timestamp: event.timestamp,
            receivedUptime: ProcessInfo.processInfo.systemUptime
        )
    }

    func setMuted(_ isMuted: Bool) {
        let center = MPNowPlayingInfoCenter.default()
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: "Winston voice mode",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isMuted ? 0.0 : 1.0,
        ]
        center.nowPlayingInfo = info
        // macOS picks its Now Playing app by this; iOS by the audio session.
        let state: MPNowPlayingPlaybackState = isMuted ? .paused : .playing
        center.playbackState = state
        // Each key as set, and its value: none of them is the user's.
        var fields = info.mapValues { "\($0)" as CustomStringConvertible }
        fields["playbackState"] = state.logName
        fields["playbackStateReadBack"] = center.playbackState.logName
        VoiceLoop.log.notice("now playing info set", fields)
    }

    func remove() {
        for (command, target, wasEnabled) in targets {
            command.removeTarget(target)
            if let wasEnabled {
                command.isEnabled = wasEnabled
            }
        }
        targets = []
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        VoiceLoop.log.notice("now playing info cleared", [
            "playbackState": MPNowPlayingPlaybackState.stopped.logName,
            "playbackStateReadBack": center.playbackState.logName,
        ])
    }
}

extension MPNowPlayingPlaybackState {
    /// For the logs.
    fileprivate var logName: String {
        switch self {
        case .unknown: "unknown"
        case .playing: "playing"
        case .paused: "paused"
        case .stopped: "stopped"
        case .interrupted: "interrupted"
        @unknown default: "\(rawValue)"
        }
    }
}

#if os(iOS)
/// A notification observer, to remove from another thread when its stream ends.
private final class ObserverToken: @unchecked Sendable {
    let observer: any NSObjectProtocol

    init(_ observer: any NSObjectProtocol) {
        self.observer = observer
    }
}
#endif

/// The audio session's route on iOS, the system's default input and output on the Mac.
@MainActor
private enum LiveAudioDevices {
    static func current() -> AudioDevices {
        #if os(iOS)
        AudioDevices(AVAudioSession.sharedInstance().currentRoute)
        #else
        AudioDevices(
            inputs: defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
            outputs: defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        )
        #endif
    }

    nonisolated static func routeChanges() -> AsyncStream<AudioRouteChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioRouteChange.self)
        #if os(iOS)
        // On the thread that posts the notification, so the current route is read as it was right
        // after this change.
        let observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) ?? .unknown
            let previous = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            continuation.yield(AudioRouteChange(
                reason,
                previous: previous.map(AudioDevices.init) ?? AudioDevices(inputs: [], outputs: []),
                current: AudioDevices(AVAudioSession.sharedInstance().currentRoute)
            ))
        }
        let token = ObserverToken(observer)
        continuation.onTermination = { _ in
            NotificationCenter.default.removeObserver(token.observer)
        }
        #else
        continuation.finish()
        #endif
        return stream
    }

    #if os(macOS)
    /// The default device that `selector` names, by its device ID. None if there is none.
    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> [AudioDevices.Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return [] }
        return [AudioDevices.Device(id: "\(device)", kind: "\(device)")]
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
