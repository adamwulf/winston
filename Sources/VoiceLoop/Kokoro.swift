@preconcurrency import AVFoundation
import Foundation
import Logging
import LogSupport
import NaturalLanguage
import Observation

// Kokoro-82M neural voices, alongside the system's `AVSpeechSynthesizer` voices. The model is
// downloaded the first time a Kokoro voice is used, and until it is ready, the best system voice
// speaks instead. The real engine is speech-swift's KokoroTTS; see `LiveKokoro.swift`.

/// Text-to-speech with the Kokoro-82M model. In the app it is speech-swift's KokoroTTS, with the
/// model stored under Application Support. Tests use a fake that needs no model or network.
package protocol KokoroEngine: Sendable {
    /// Downloads the model if it isn't stored yet, then loads it. Does nothing once loaded.
    /// `downloadProgress` gets the download's progress, from 0 to 1, and is not called when the
    /// model is already stored. It may be called on any thread.
    func load(downloadProgress: @escaping @Sendable (Double) -> Void) async throws
    /// `text` spoken by `voice` (a Kokoro voice id such as `af_heart`) at `speed` (1 is normal),
    /// as 24 kHz mono samples. Throws if the model isn't loaded.
    func synthesize(_ text: String, voice: String, speed: Float) async throws -> [Float]
}

/// Where the Kokoro model is, for the settings screen.
public enum KokoroModelState: Sendable, Equatable {
    /// Nothing has asked for the model yet in this run. It may already be stored.
    case notLoaded
    /// Loading the stored model.
    case loading
    /// Downloading the model, `progress` from 0 to 1. At 1 the download is done and the
    /// model is loading.
    case downloading(progress: Double)
    /// Kokoro voices speak.
    case ready
    /// Downloading or loading failed. The system voice speaks until a retry works.
    case failed
}

/// The model's state, and loading it on demand. One per voice loop.
@MainActor
@Observable
final class KokoroModel {
    private static let log = Logger(label: "voice.kokoro")

    private(set) var state: KokoroModelState = .notLoaded
    @ObservationIgnored let engine: any KokoroEngine

    init(engine: any KokoroEngine) {
        self.engine = engine
    }

    /// Downloads and loads the model, unless it is ready or already on its way. After a failure,
    /// tries again.
    func load() {
        switch state {
        case .loading, .downloading, .ready:
            return
        case .notLoaded, .failed:
            break
        }
        state = .loading
        let started = ContinuousClock.now
        Task {
            do {
                try await engine.load { progress in
                    Task { @MainActor in
                        self.downloaded(progress)
                    }
                }
                state = .ready
                Self.log.notice("kokoro model ready", ["ms": Int(started.duration(to: .now) / .milliseconds(1))])
            } catch {
                state = .failed
                // Codes only: the downloader's messages name the model's folder.
                Self.log.error("kokoro model load failed", error.logCodes())
            }
        }
    }

    /// Progress can arrive after the load has finished; it only counts while loading.
    private func downloaded(_ progress: Double) {
        switch state {
        case .loading, .downloading:
            state = .downloading(progress: min(max(progress, 0), 1))
        case .notLoaded, .ready, .failed:
            break
        }
    }
}

/// The Kokoro voices offered in settings.
enum KokoroCatalog {
    /// Starts every Kokoro `VoiceOption.id`, so none can be mistaken for an
    /// `AVSpeechSynthesisVoice.identifier`.
    static let idPrefix = "kokoro."

    /// American English voices (Kokoro's `a` prefix): the Kokoro voice id and its name. Best
    /// first, by the overall grade in hexgrad/Kokoro-82M's VOICES.md, shown after each; voices
    /// with the same grade keep that table's order. `am_santa` (D-) is left out as a novelty
    /// voice, as system novelty voices are.
    static let american: [(id: String, name: String)] = [
        ("af_heart", "Heart"), // A
        ("af_bella", "Bella"), // A-
        ("af_nicole", "Nicole"), // B-
        ("af_aoede", "Aoede"), // C+
        ("af_kore", "Kore"), // C+
        ("af_sarah", "Sarah"), // C+
        ("am_fenrir", "Fenrir"), // C+
        ("am_michael", "Michael"), // C+
        ("am_puck", "Puck"), // C+
        ("af_alloy", "Alloy"), // C
        ("af_nova", "Nova"), // C
        ("af_sky", "Sky"), // C-
        ("af_jessica", "Jessica"), // D
        ("af_river", "River"), // D
        ("am_echo", "Echo"), // D
        ("am_eric", "Eric"), // D
        ("am_liam", "Liam"), // D
        ("am_onyx", "Onyx"), // D
        ("am_adam", "Adam"), // F+
    ]

    /// British English voices (Kokoro's `b` prefix), in the same order. KokoroTTS loads only
    /// its American pronunciation dictionaries, so these have a British voice but American
    /// pronunciation.
    static let british: [(id: String, name: String)] = [
        ("bf_emma", "Emma"), // B-
        ("bf_isabella", "Isabella"), // C
        ("bm_fable", "Fable"), // C
        ("bm_george", "George"), // C
        ("bm_lewis", "Lewis"), // D+
        ("bf_alice", "Alice"), // D
        ("bf_lily", "Lily"), // D
        ("bm_daniel", "Daniel"), // D
    ]

    /// The Kokoro voices for a language code such as `AVSpeechSynthesisVoice.currentLanguageCode()`
    /// returns: American voices for en-US, British for en-GB, and none for any other language.
    static func voices(forLanguage language: String) -> [VoiceOption] {
        let voices = switch language {
        case "en-US": american
        case "en-GB": british
        default: [(id: String, name: String)]()
        }
        return voices.map { VoiceOption(id: idPrefix + $0.id, name: $0.name, quality: .standard, engine: .kokoro) }
    }

    /// The Kokoro voice id (`af_heart`) for a `VoiceOption.id` (`kokoro.af_heart`) in either
    /// language, or nil for any other id.
    static func kokoroVoice(forOptionID optionID: String) -> String? {
        guard optionID.hasPrefix(idPrefix) else { return nil }
        let voice = String(optionID.dropFirst(idPrefix.count))
        return (american + british).contains { $0.id == voice } ? voice : nil
    }
}

/// How a message is cut up for Kokoro.
enum KokoroText {
    /// `text`'s sentences, in order, one line at a time: Kokoro renders a sentence at a time, so
    /// the first can start playing while the rest are rendered. Lines without punctuation, such
    /// as list items, are sentences of their own.
    static func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        var sentences: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let line = String(line)
            tokenizer.string = line
            tokenizer.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in
                let sentence = line[range].trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty {
                    sentences.append(sentence)
                }
                return true
            }
        }
        return sentences
    }
}

/// Kokoro's speaking speed for a speech rate.
enum KokoroSpeed {
    /// The Kokoro speed for an `AVSpeechUtterance.rate` within `VoiceLoop.speechRates`. The
    /// normal rate is speed 1, and each end of the range halves or doubles it, which is about
    /// how much the system voices slow down and speed up.
    static func speed(forRate rate: Float) -> Float {
        // `VoiceLoop.speechRates` and `VoiceLoop.defaultSpeechRate`, which are main-actor isolated.
        let slowest = AVSpeechUtteranceMinimumSpeechRate
        let fastest = AVSpeechUtteranceMaximumSpeechRate
        let normal = AVSpeechUtteranceDefaultSpeechRate
        let clamped = min(max(rate, slowest), fastest)
        // -1 at the slowest rate, 0 at normal, 1 at the fastest.
        let position = clamped < normal
            ? (clamped - normal) / (normal - slowest)
            : (clamped - normal) / (fastest - normal)
        return pow(2, position)
    }
}

/// Kokoro's audio as buffers for `SpeechPlayback`.
enum KokoroAudio {
    static let sampleRate = 24_000.0
    /// Frames per buffer: 0.1 s. `SpeechPlayback` holds back a message's newest buffer until the
    /// next one arrives (so the last can carry the completion handler). With short buffers that
    /// is only the tail of a sentence's trailing silence, so a sentence plays as soon as it is
    /// rendered rather than waiting for the next one.
    static let framesPerBuffer = 2_400

    /// `samples` (24 kHz mono) as consecutive buffers of at most `framesPerBuffer` frames.
    static func buffers(_ samples: [Float]) -> [AVAudioPCMBuffer] {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return [] }
        return stride(from: 0, to: samples.count, by: framesPerBuffer).compactMap { start in
            let count = min(framesPerBuffer, samples.count - start)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else { return nil }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress! + start, count: count)
            }
            return buffer
        }
    }
}
