import Foundation

/// A part of a chunk Speak IPA says (`IPASpeech.say(_:)`).
public enum IPASpeechPart: Hashable, Sendable {
    /// A word said with phonemes in Kokoro's notation (see `Pronunciation.Mode.phonetic`), as a
    /// phonetic pronunciation's word is: through placeholders (`PhoneticPlaceholders`), a set of
    /// the message's own.
    case phonemes(word: String, phonemes: String)
    /// Text said as written, with the pronunciations in settings: what lies between words, or a
    /// word without phonemes.
    case text(String)
}

/// How a message `VoiceLoop.startIPASpeech(request:onFirstSound:onEnded:)` said ended.
public enum IPASpeechEnd: Hashable, Sendable {
    /// It played to the end, after `IPASpeech.finish()`.
    case finished
    /// It was stopped, or cut off: by `IPASpeech.stop()`, another preview, voice mode starting,
    /// the audio hardware changing, or a call.
    case stopped
    /// Kokoro failed partway, or its model was freed: the system voice said the rest of the
    /// chunk it was on, and no later chunk was said.
    case kokoroFailed

    /// As the logs name it.
    public var logName: String {
        switch self {
        case .finished: "finished"
        case .stopped: "stopped"
        case .kokoroFailed: "kokoroFailed"
        }
    }
}

/// Why `VoiceLoop.startIPASpeech(request:onFirstSound:onEnded:)` couldn't start.
public enum IPASpeechError: Error, Equatable, Sendable {
    /// Voice mode is on, or starting: replies, barge-in and echo cancellation have the loop's
    /// engine, so Speak IPA waits until it is off.
    case voiceModeOn
    /// No Kokoro voice is chosen, or its model isn't ready: only Kokoro says phonemes.
    case kokoroNotReady
}

/// A message Speak IPA says a chunk at a time, as each is ready, made by
/// `VoiceLoop.startIPASpeech(request:onFirstSound:onEnded:)`. Chunks play in the order they are given,
/// each as soon as Kokoro has rendered it and the one before has played; `finish()` says no more
/// are coming. Once the speech has ended (it played to the end, `stop()`, or something else took
/// the speaker), `say(_:)` and `sayAsWritten(_:)` return false.
@MainActor
public final class IPASpeech {
    /// Which speech this is, for the loop: a newer one has a higher number.
    let id: Int
    private weak var loop: VoiceLoop?

    init(id: Int, loop: VoiceLoop) {
        self.id = id
        self.loop = loop
    }

    /// Queues a chunk as its parts, after the chunks before it. Returns whether it was queued:
    /// false once the speech has ended or `finish()` was called.
    @discardableResult
    public func say(_ parts: [IPASpeechPart]) -> Bool {
        loop?.sayIPAChunk(parts, speech: id) ?? false
    }

    /// Queues a chunk said as written, with the pronunciations in settings, as a reply is: for a
    /// chunk whose IPA couldn't be used. Returns what `say(_:)` does.
    @discardableResult
    public func sayAsWritten(_ text: String) -> Bool {
        say([.text(text)])
    }

    /// No more chunks are coming: the speech ends once those queued have played.
    public func finish() {
        loop?.finishIPASpeech(id)
    }

    /// Stops the speech now, if it hasn't ended, and drops the chunks still queued.
    public func stop() {
        loop?.stopIPASpeech(id)
    }
}
