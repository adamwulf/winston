// Audio-session interruptions (a phone call, Siri, another app's audio) only exist on iOS, and
// so does the code that handles them. These tests run on an iOS simulator:
//
//     xcodebuild test -scheme Winston-Package -destination "platform=iOS Simulator,name=<device>"
//
// They are a test target of their own because the voice loop listens for interruptions
// process-wide: a test that posts one would disturb every other loop running in the same
// process. Each test target runs in its own process.
#if os(iOS)
import AVFoundation
import Testing
import UIKit
import VoiceLoop
import VoiceLoopTestSupport

/// Posts what iOS posts when another app takes the audio session, or gives it back.
@MainActor
private func postInterruption(
    _ type: AVAudioSession.InterruptionType,
    options: AVAudioSession.InterruptionOptions = []
) {
    var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
    if type == .ended {
        info[AVAudioSessionInterruptionOptionKey] = options.rawValue
    }
    NotificationCenter.default.post(
        name: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance(),
        userInfo: info
    )
}

/// Posts what iOS posts when the app comes back to the foreground.
@MainActor
private func postDidBecomeActive() {
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
}

@MainActor
private func startedLoop(on bed: VoiceTestBed) async throws -> VoiceLoop {
    let loop = bed.makeLoop()
    loop.pauseThreshold = .milliseconds(50)
    try await loop.start()
    return loop
}

/// Lets queued main-actor work run for a moment, before checking that something did NOT happen.
private func settle(_ duration: Duration = .milliseconds(250)) async throws {
    try await Task.sleep(for: duration)
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct InterruptionTests {
    @Test func anInterruptionPausesListeningAndItsEndResumesIt() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        postInterruption(.began)

        // The engine is gone, but voice mode is still on: the loop shows it is listening.
        #expect(await eventually { bed.audio.engines.last?.isRunning == false })
        #expect(await eventually { bed.recognizer.isCancelled })
        #expect(loop.state == .listening(partial: ""))

        postInterruption(.ended, options: .shouldResume)

        #expect(await eventually { bed.recognizers.count == 2 && bed.recognizer.isStarted })
        #expect(loop.state == .listening(partial: ""))
        #expect(bed.audio.engines.last?.isRunning == true)
    }

    @Test func anInterruptionThatMayNotBeResumedTurnsTheLoopOff() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)

        postInterruption(.began)
        #expect(await eventually { bed.audio.engines.last?.isRunning == false })
        postInterruption(.ended)

        #expect(await eventually { loop.state == .off })
        #expect(bed.recognizers.count == 1)
    }

    @Test func anInterruptionWhileOffIsIgnored() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()

        postInterruption(.began)
        postInterruption(.ended, options: .shouldResume)
        try await settle()

        #expect(loop.state == .off)
        #expect(bed.recognizers.isEmpty)
    }

    @Test func anEndWithoutABeginningChangesNothing() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        postInterruption(.ended, options: .shouldResume)
        try await settle()

        #expect(loop.state == .listening(partial: ""))
        #expect(bed.recognizers.count == 1)
        #expect(bed.audio.engines.last?.isRunning == true)
    }

    @Test func aNotificationThatDoesNotSayWhatHappenedIsIgnored() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil)
        try await settle()

        #expect(loop.state == .listening(partial: ""))
        #expect(bed.recognizers.count == 1)
        #expect(bed.audio.engines.last?.isRunning == true)
    }

    @Test func aReplyCutOffByAnInterruptionIsSpokenAfterIt() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        loop.speak("Hi there, how are you doing today?")
        #expect(await eventually { bed.audio.playedFrames > 0 })
        postInterruption(.began)
        #expect(await eventually { bed.audio.engines.last?.isRunning == false })
        #expect(loop.state == .listening(partial: ""))
        let playedBeforeInterruption = bed.audio.playedFrames

        postInterruption(.ended, options: .shouldResume)

        #expect(await eventually { bed.audio.engines.count == 2 && loop.state == .speaking })
        #expect(await eventually { bed.audio.playedFrames > playedBeforeInterruption })
    }

    @Test func anInterruptionDuringAStartAbandonsItUntilTheInterruptionEnds() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        defer { loop.stop() }
        bed.whenRequestingPermissions = {
            postInterruption(.began)
            // Long enough for the loop to hear of it while the permission request is pending.
            try? await Task.sleep(for: .milliseconds(100))
        }

        try await loop.start()

        // No engine was built, and voice mode is still on, waiting for the interruption to end.
        #expect(bed.audio.engines.isEmpty)
        #expect(loop.state == .listening(partial: ""))

        bed.whenRequestingPermissions = {}
        postInterruption(.ended, options: .shouldResume)

        #expect(await eventually { bed.recognizers.last?.isStarted == true })
        #expect(loop.state == .listening(partial: ""))
        #expect(bed.audio.engines.last?.isRunning == true)
    }

    @Test func whenTheEndOfAnInterruptionNeverComesReturningToTheAppResumes() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        postInterruption(.began)
        #expect(await eventually { bed.audio.engines.last?.isRunning == false })
        // A call that keeps the audio session: iOS never reports the interruption's end.
        postDidBecomeActive()

        #expect(await eventually { bed.recognizers.count == 2 && bed.recognizer.isStarted })
        #expect(loop.state == .listening(partial: ""))

        // The end arriving late changes nothing: the loop has already resumed.
        postInterruption(.ended, options: .shouldResume)
        try await settle()
        #expect(bed.recognizers.count == 2)
    }

    @Test func returningToTheAppWithNoInterruptionChangesNothing() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        postDidBecomeActive()
        try await settle()

        #expect(loop.state == .listening(partial: ""))
        #expect(bed.recognizers.count == 1)
    }

    @Test func aFailedRetryOnReturningToTheAppStillResumesWhenTheInterruptionEnds() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }

        postInterruption(.began)
        #expect(await eventually { bed.audio.engines.last?.isRunning == false })
        // Adam comes back mid-call: the retry can't start the engine yet.
        bed.engineError = AVAudioSessionStillBusy()
        postDidBecomeActive()
        #expect(await eventually { loop.state == .off })

        // A reply that arrives meanwhile is kept for the resume.
        loop.speak("Hi.")
        #expect(loop.state == .off)

        bed.engineError = nil
        postInterruption(.ended, options: .shouldResume)

        #expect(await eventually { loop.state == .speaking })
        #expect(await eventually { loop.state == .listening(partial: "") })
        #expect(bed.audio.playedFrames > 0)
    }

    // MARK: - The audio session
    //
    // In this suite because the session is process-wide too.

    @Test func withVoiceProcessingTheSessionIsAVoiceChatThatPausesOtherAudio() async throws {
        let bed = VoiceTestBed()
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        let session = AVAudioSession.sharedInstance()

        #expect(session.category == .playAndRecord)
        #expect(session.mode == .voiceChat)
        #expect(session.categoryOptions.contains(.defaultToSpeaker))
        #expect(!session.categoryOptions.contains(.mixWithOthers))
    }

    @Test func withoutVoiceProcessingTheSessionKeepsTheDefaultMode() async throws {
        let bed = VoiceTestBed()
        bed.hasVoiceProcessing = false
        let loop = try await startedLoop(on: bed)
        defer { loop.stop() }
        let session = AVAudioSession.sharedInstance()

        // Voice chat without voice processing would only lower the playback level.
        #expect(session.category == .playAndRecord)
        #expect(session.mode == .default)
    }

    @Test func withPauseOtherAudioOffTheSessionMixesWithOtherAudio() async throws {
        let bed = VoiceTestBed()
        let loop = bed.makeLoop()
        loop.pausesOtherAudio = false
        try await loop.start()
        defer { loop.stop() }
        let session = AVAudioSession.sharedInstance()
        #expect(session.categoryOptions.contains(.mixWithOthers))

        // Turned back on while listening: the engine is rebuilt and the session interrupts again.
        loop.pausesOtherAudio = true

        #expect(await eventually { bed.recognizers.count == 2 && bed.recognizer.isStarted })
        #expect(!session.categoryOptions.contains(.mixWithOthers))
        #expect(loop.state == .listening(partial: ""))
    }
}

/// Stands for the engine failing to start while another app still holds the audio session.
private struct AVAudioSessionStillBusy: Error {}
#endif
