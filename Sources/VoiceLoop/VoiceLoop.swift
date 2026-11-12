import Foundation
import Observation

/// Hands-free voice loop: listens, detects the end of an utterance, speaks replies,
/// and stops speaking when the user talks over it (barge-in).
@MainActor
@Observable
public final class VoiceLoop {
    public enum State: Sendable, Equatable {
        case off
        /// Listening; `partial` is the live transcript of the current utterance (may be empty).
        case listening(partial: String)
        /// Speaking a reply. Listening continues so the user can interrupt.
        case speaking
    }

    public private(set) var state: State = .off
    /// How long the transcript must stay unchanged before an utterance is finished.
    public var pauseThreshold: Duration = .milliseconds(1200)
    /// `AVSpeechSynthesisVoice.identifier` to speak with; nil picks the best installed voice.
    public var voiceIdentifier: String?

    /// One element per finished utterance. Single consumer.
    @ObservationIgnored public let utterances: AsyncStream<Utterance>
    @ObservationIgnored private let utteranceContinuation: AsyncStream<Utterance>.Continuation

    public init() {
        (utterances, utteranceContinuation) = AsyncStream.makeStream(of: Utterance.self)
    }

    /// Starts listening. Asks for microphone and speech permission on first use.
    public func start() async throws {
        throw VoiceLoopError.notImplemented
    }

    /// Stops listening and speaking.
    public func stop() {
    }

    /// Drops the utterance in progress without sending it.
    public func discardCurrentUtterance() {
    }

    /// Queues `text` to be spoken after anything already queued. Strips markdown/code first.
    public func speak(_ text: String) {
    }

    /// Stops speaking and clears the queue.
    public func stopSpeaking() {
    }

    /// Installed voices for the current language, best quality first, for a settings picker.
    public static func availableVoices() -> [VoiceOption] {
        []
    }
}

/// A text-to-speech voice the user can pick.
public struct VoiceOption: Identifiable, Hashable, Sendable {
    /// `AVSpeechSynthesisVoice.identifier`.
    public let id: String
    public let name: String
    public let quality: Quality

    public enum Quality: Int, Comparable, Sendable {
        case standard, enhanced, premium
        public static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public init(id: String, name: String, quality: Quality) {
        self.id = id
        self.name = name
        self.quality = quality
    }
}

public enum VoiceLoopError: Error, Sendable, Equatable {
    case notImplemented
    case microphonePermissionDenied
    case speechPermissionDenied
    case speechModelUnavailable
}
