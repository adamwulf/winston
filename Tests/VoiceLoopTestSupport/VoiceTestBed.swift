@preconcurrency import AVFoundation
import VoiceLoop

/// Everything a `VoiceLoop` needs from the system, for tests: offline audio hardware, scripted
/// recognizers, permission prompts that answer at once, a fake Kokoro, a clock that moves only
/// when the test moves it, and user defaults kept in memory. The loop built on it is the real
/// `VoiceLoop`, with its real pipeline and its real speech synthesizer.
@MainActor
package final class VoiceTestBed {
    package let audio = OfflineAudio()
    package let kokoro = FakeKokoro()
    /// Every recognizer the loop has asked for, newest last. Each listening session gets one.
    package private(set) var recognizers: [ScriptedRecognizer] = []

    /// When set, the permission request fails with it.
    package var permissionError: VoiceLoopError?
    /// When set, there is no speech model: making a recognizer fails with it.
    package var recognizerError: (any Error)?
    /// When set, the next recognizer fails to start with it.
    package var recognizerStartError: (any Error)?
    /// When set, creating an audio engine fails with it.
    package var engineError: (any Error)?
    /// Whether the microphone can do voice processing (echo cancellation).
    package var hasVoiceProcessing = true
    /// How many times the loop has tried to turn voice processing on.
    package private(set) var voiceProcessingAttempts = 0
    /// The audio devices in use: the built-in microphone and speaker unless a test changes them.
    /// On the Mac voice mode checks them every 100 ms; on iOS it goes by the routes that
    /// `reportRouteChange(isDeviceChange:from:to:)` reports.
    package var audioDevices = VoiceTestBed.builtInDevices
    /// The built-in microphone and speaker.
    package nonisolated static let builtInDevices = AudioDevices(
        inputs: [.init(id: "built-in-microphone", kind: "MicrophoneBuiltIn")],
        outputs: [.init(id: "built-in-speaker", kind: "Speaker")]
    )
    /// Each stream of route changes a loop asked for.
    private var routeChanges: [AsyncStream<AudioRouteChange>.Continuation] = []
    /// The system's language. American English unless a test changes it, so the American Kokoro
    /// voices (`af_heart` and the like) are on offer whatever the Mac running the tests uses.
    package var languageCode = "en-US"
    /// The installed system voices, whatever the language. The Mac's own unless a test sets them.
    package var systemVoices: [VoiceOption]?
    /// The language of each time the loop listed the system voices, oldest first.
    package private(set) var systemVoiceListings: [String] = []
    /// The wall clock. It stands still until a test moves it, as by a day.
    package var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// When the loop recorded that the last Kokoro voice was unchosen, as the app keeps it in its
    /// user defaults. A loop made later on the same bed sees it, as after a relaunch.
    package var kokoroUnchosenSince: Date?
    /// The text of each utterance the system voice was given, oldest first, by every loop on
    /// this bed: replies and previews.
    package private(set) var systemVoiceTexts: [String] = []

    /// Runs while the loop waits for permission, for tests of what happens meanwhile.
    package var whenRequestingPermissions: @MainActor () async -> Void = {}
    /// Runs while the loop waits for a recognizer to start.
    package var whenRecognizerStarts: @MainActor () async -> Void = {}

    package init() {}

    package var environment: VoiceEnvironment {
        VoiceEnvironment(
            requestPermissions: { [self] in
                await whenRequestingPermissions()
                if let permissionError {
                    throw permissionError
                }
            },
            makeRecognizer: { [self] in
                if let recognizerError {
                    throw recognizerError
                }
                let recognizer = ScriptedRecognizer(startError: recognizerStartError) { [self] in
                    await whenRecognizerStarts()
                }
                recognizerStartError = nil
                recognizers.append(recognizer)
                return recognizer
            },
            makeEngine: { [self] in
                if let engineError {
                    throw engineError
                }
                return try audio.makeEngine()
            },
            enableVoiceProcessing: { [self] _ in
                voiceProcessingAttempts += 1
                if !hasVoiceProcessing {
                    throw VoiceTestBedError.noVoiceProcessing
                }
            },
            audioDevices: { [self] in audioDevices },
            audioRouteChanges: { [self] in
                let (stream, continuation) = AsyncStream.makeStream(of: AudioRouteChange.self)
                routeChanges.append(continuation)
                return stream
            },
            kokoro: kokoro,
            languageCode: { [self] in languageCode },
            systemVoices: { [self] language in
                systemVoiceListings.append(language)
                return systemVoices ?? VoiceLoop.systemVoices(language: language)
            },
            now: { [self] in now },
            kokoroUnchosenSince: { [self] in kokoroUnchosenSince },
            setKokoroUnchosenSince: { [self] in kokoroUnchosenSince = $0 },
            systemVoiceWillSay: { [self] in systemVoiceTexts.append($0) }
        )
    }

    /// A voice loop on this test bed. Its sound cues are off unless `soundCues` is true, so the
    /// only sound it makes is what it says.
    package func makeLoop(soundCues: Bool = false) -> VoiceLoop {
        let loop = VoiceLoop(environment: environment)
        loop.playsSoundCues = soundCues
        return loop
    }

    /// Tells every loop on this bed that the iOS audio session's route changed from `previous` to
    /// `current`: with `isDeviceChange`, because a device came or went (`.newDeviceAvailable`),
    /// otherwise for another reason (`.override`). It leaves `audioDevices` alone.
    package func reportRouteChange(isDeviceChange: Bool, from previous: AudioDevices, to current: AudioDevices) {
        let change = AudioRouteChange(
            isDeviceChange: isDeviceChange,
            reason: isDeviceChange ? "newDeviceAvailable" : "override",
            previous: previous,
            current: current
        )
        for continuation in routeChanges {
            continuation.yield(change)
        }
    }

    /// The current listening session's recognizer.
    package var recognizer: ScriptedRecognizer {
        guard let recognizer = recognizers.last else {
            preconditionFailure("the loop hasn't asked for a recognizer yet")
        }
        return recognizer
    }
}

package enum VoiceTestBedError: Error {
    /// The pretend microphone can't do voice processing.
    case noVoiceProcessing
}

/// Waits until `condition` holds, letting the main actor run in between. Returns false if it
/// still doesn't hold after `timeout`.
@MainActor
package func eventually(
    timeout: Duration = .seconds(10),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline {
            return false
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
