import Foundation

/// Turns a bot message into text that sounds right when spoken.
public enum SpokenText {
    /// Drops fenced code blocks, strips leftover markdown symbols, turns `[text](url)` into
    /// "text", says bare URLs as "a link", and shortens long file paths.
    public static func speakable(_ text: String) -> String {
        // Implemented in the VoiceLoop work (see PLAN.md, "SpokenText").
        text
    }
}
