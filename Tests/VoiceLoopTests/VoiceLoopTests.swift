import Testing
@testable import VoiceLoop

@Test func utteranceMessageHasVoicePrefix() {
    #expect(Utterance(text: "hello").messageText.hasPrefix("🎙️ "))
}
