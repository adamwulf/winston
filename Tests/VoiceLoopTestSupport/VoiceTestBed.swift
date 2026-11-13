@preconcurrency import AVFoundation
import VoiceLoop

/// Everything a `VoiceLoop` needs from the system, for tests: offline audio hardware, scripted
/// recognizers, and permission prompts that answer at once. The loop built on it is the real
/// `VoiceLoop`, with its real pipeline and its real speech synthesizer.
@MainActor
package final class VoiceTestBed {
    package let audio = OfflineAudio()
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
                if !hasVoiceProcessing {
                    throw VoiceTestBedError.noVoiceProcessing
                }
            }
        )
    }

    /// A voice loop on this test bed.
    package func makeLoop() -> VoiceLoop {
        VoiceLoop(environment: environment)
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
