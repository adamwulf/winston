import Foundation

/// One finished spoken message: what was heard, plus the recognizer's other readings.
public struct Utterance: Sendable, Equatable {
    /// The most likely transcription.
    public var text: String
    /// Other readings of phrases that differ from `text`, most likely first. At most two are used.
    public var alternatives: [String]

    public init(text: String, alternatives: [String] = []) {
        self.text = text
        self.alternatives = alternatives
    }

    /// The Telegram message body: `🎙️ <text>`, plus ` (alt: …)` when the recognizer
    /// heard something different. Always a single message.
    public var messageText: String {
        // Implemented in the VoiceLoop work (see PLAN.md, "Voice mode").
        "🎙️ " + text
    }
}
