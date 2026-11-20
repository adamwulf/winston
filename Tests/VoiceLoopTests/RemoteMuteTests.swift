import Testing
import VoiceLoop
import VoiceLoopTestSupport

/// Stands in for the system's media remote commands and Now Playing info, and for the app's
/// input mute.
@MainActor
private final class FakeNowPlaying: NowPlaying {
    /// What the loop calls with each command, while it takes them.
    private(set) var handler: (@MainActor @Sendable (RemoteCommandEvent) -> Void)?
    /// Whether the loop has stopped taking the commands.
    private(set) var isRemoved = false
    /// Each mute state voice mode was shown with, oldest first.
    private(set) var shownMuted: [Bool] = []
    /// Each mute the loop asked for, oldest first.
    var inputMutes: [Bool] = []

    func install(
        isMuted: Bool,
        handler: @escaping @MainActor @Sendable (RemoteCommandEvent) -> Void
    ) -> [RemoteCommandRegistration] {
        self.handler = handler
        shownMuted.append(isMuted)
        return []
    }

    func setMuted(_ isMuted: Bool) {
        shownMuted.append(isMuted)
    }

    func remove() {
        handler = nil
        isRemoved = true
    }

    /// A press of the AirPods stem, as the system sends it.
    func press(_ command: RemoteCommand) {
        handler?(RemoteCommandEvent(name: command.rawValue, command: command, timestamp: 1, receivedUptime: 1.001))
    }

    /// A command the loop only logs, such as `nextTrack`.
    func press(loggedOnly name: String) {
        handler?(RemoteCommandEvent(name: name, command: nil, timestamp: 1, receivedUptime: 1.001))
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RemoteMuteTests {
    @Test func theRemoteCommandsComeAndGoWithVoiceModeAndEachTogglesTheMute() async throws {
        let bed = VoiceTestBed()
        let nowPlaying = FakeNowPlaying()
        var environment = bed.environment
        environment.makeNowPlaying = { nowPlaying }
        environment.setInputMuted = { nowPlaying.inputMutes.append($0) }
        let loop = VoiceLoop(environment: environment)
        loop.playsSoundCues = false
        #expect(nowPlaying.handler == nil)

        try await loop.start()
        #expect(nowPlaying.handler != nil)
        #expect(nowPlaying.shownMuted == [false])

        nowPlaying.press(.togglePlayPause)
        #expect(loop.isInputMuted)
        nowPlaying.press(.play)
        #expect(!loop.isInputMuted)
        nowPlaying.press(.pause)
        #expect(loop.isInputMuted)
        #expect(nowPlaying.inputMutes == [true, false, true])
        #expect(nowPlaying.shownMuted == [false, true, false, true])

        loop.stop()
        #expect(nowPlaying.isRemoved)
        #expect(!loop.isInputMuted)
    }

    @Test func aCommandThatIsOnlyLoggedLeavesTheMuteAlone() async throws {
        let bed = VoiceTestBed()
        let nowPlaying = FakeNowPlaying()
        var environment = bed.environment
        environment.makeNowPlaying = { nowPlaying }
        environment.setInputMuted = { nowPlaying.inputMutes.append($0) }
        let loop = VoiceLoop(environment: environment)
        loop.playsSoundCues = false
        try await loop.start()

        nowPlaying.press(loggedOnly: "nextTrack")
        #expect(!loop.isInputMuted)
        #expect(nowPlaying.inputMutes.isEmpty)
        #expect(nowPlaying.shownMuted == [false])
        loop.stop()
    }

    @Test func theInstallLogNamesTheCommandsTakenAndLoggedAndWhichAreEnabled() {
        let context = VoiceLoop.registrationContext([
            RemoteCommandRegistration(name: "togglePlayPause", isEnabled: true, isHandled: true),
            RemoteCommandRegistration(name: "play", isEnabled: true, isHandled: true),
            RemoteCommandRegistration(name: "nextTrack", isEnabled: false, isHandled: false),
            RemoteCommandRegistration(name: "like", isEnabled: false, isHandled: false),
        ]).mapValues(\.description)
        #expect(context == [
            "handled": "togglePlayPause,play",
            "handledEnabled": "togglePlayPause,play",
            "logOnly": "nextTrack,like",
            "logOnlyEnabled": "none",
        ])
    }
}
