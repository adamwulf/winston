import Foundation
import Observation
import TelegramLink
import TelegramLinkTestSupport
import VoiceLoop
import VoiceLoopTestSupport
import WinstonCore

// TDLibKit isn't imported in this target: it has its own `ChatEvent`, `Message` and `File`.
// The builders in TelegramLinkTestSupport make the TDLibKit values the tests hand to the fake.

/// An `AppModel` as the app builds it, except for the three things a test can't have: TDLib is
/// `FakeTDLib` behind the real `TelegramLink`, the voice loop is the real `VoiceLoop` on a
/// `VoiceTestBed` (offline audio, scripted recognizer), and the settings go to user defaults
/// of the harness's own.
@MainActor
final class Harness {
    let fake: FakeTDLib
    let bed = VoiceTestBed()
    let defaults: UserDefaults
    let model: AppModel
    private let suiteName: String

    /// - Parameters:
    ///   - fake: the pretend Telegram account. Logged in, with no chats, by default.
    ///   - settings: values already in the user defaults when the model starts up.
    ///   - soundCues: whether the voice loop plays its sound cues. Off by default, so the only
    ///     sound in voice mode is what is spoken.
    init(fake: FakeTDLib = FakeTDLib(), settings: [String: Any] = [:], soundCues: Bool = false) {
        self.fake = fake
        suiteName = "winston-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("couldn't create user defaults for \(suiteName)")
        }
        self.defaults = defaults
        for (key, value) in settings {
            defaults.set(value, forKey: key)
        }
        model = AppModel(
            link: fake.makeLink(typingTimeout: .seconds(60)),
            voiceLoop: bed.makeLoop(soundCues: soundCues),
            defaults: defaults
        )
    }

    isolated deinit {
        model.voiceLoop.stop()
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Another model reading the same user defaults, as after the app is relaunched. `bed` is
    /// the new launch's voice hardware and system, such as one in another language.
    func relaunchedModel(on bed: VoiceTestBed = VoiceTestBed()) -> AppModel {
        AppModel(link: FakeTDLib().makeLink(), voiceLoop: bed.makeLoop(), defaults: defaults)
    }

    /// Two bot chats, Home (chat 1) and Laptop (chat 2), listed newest first as TDLib does,
    /// each with a little history.
    /// - Parameters:
    ///   - settings: values already in the user defaults when the model starts up.
    ///   - soundCues: whether the voice loop plays its sound cues.
    static func withTwoBots(settings: [String: Any] = [:], soundCues: Bool = false) -> Harness {
        let fake = FakeTDLib()
        fake.addBotChat(id: 2, title: "Laptop", username: "laptop_bot")
        fake.addBotChat(id: 1, title: "Home", username: "home_bot")
        fake.addHistory([
            textMessage(id: 10, chatID: 1, isOutgoing: true, "What's on the build server?"),
            textMessage(id: 11, chatID: 1, "Two jobs are queued."),
            textMessage(id: 20, chatID: 2, "The coordinator is offline."),
        ])
        return Harness(fake: fake, settings: settings, soundCues: soundCues)
    }

    /// Starts the model and waits until it is logged in with its chats and their history loaded.
    func startAndLoadChats() async -> Bool {
        model.start()
        return await eventually { [self] in
            model.authState == .ready && model.chatsLoaded
                && model.chats.allSatisfy { model.messages[$0.id] != nil }
        }
    }
}

/// Every value a property of an observable model takes, in order, from when the log is made:
/// what a view showing it would see change. For states that pass too quickly to catch with
/// `eventually`, such as the login states of a logout.
@MainActor
final class ValueLog<Value> {
    private let read: @MainActor () -> Value
    /// The value before each change so far.
    private var earlier: [Value] = []

    init(_ read: @escaping @MainActor () -> Value) {
        self.read = read
        observe()
    }

    /// The values so far, the current one last.
    var values: [Value] {
        earlier + [read()]
    }

    private func observe() {
        withObservationTracking {
            _ = read()
        } onChange: { [weak self] in
            // Called on the main actor just before each change, so `read()` still gives the old value.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.earlier.append(self.read())
                self.observe()
            }
        }
    }
}

/// Lets queued main-actor work, TDLib's updates and the audio engine run for a moment, before
/// checking that something did NOT happen.
func settle(_ duration: Duration = .milliseconds(250)) async throws {
    try await Task.sleep(for: duration)
}
