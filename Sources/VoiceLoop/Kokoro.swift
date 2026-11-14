@preconcurrency import AVFoundation
import Foundation
import Logging
import LogSupport
import NaturalLanguage
import Observation

// Kokoro-82M neural voices, alongside the system's `AVSpeechSynthesizer` voices. The chosen model
// (see `KokoroModelVariant`) is downloaded the first time a Kokoro voice is used with it, and
// until it is ready, the best system voice speaks instead. Once no Kokoro voice has been chosen
// for a day, the stored models are deleted. The real engine is speech-swift's KokoroTTS; see
// `LiveKokoro.swift`.

/// Which Kokoro model speaks the Kokoro voices: one of four end-to-end graphs, each rendering up to
/// a fixed length of speech per pass. A longer sentence is cut into pieces, and the tone of voice
/// resets at each cut; a pass costs the same however short the sentence. Each model downloads the
/// first time it is used, and stays stored until the stored models are deleted, a day after the
/// last Kokoro voice was unchosen.
public enum KokoroModelVariant: String, CaseIterable, Sendable {
    /// speech-swift's 5 s graph: about 56 phoneme tokens per pass. The only one that speaks at
    /// the speech rate (FluidAudio's graphs have no speed input, so they speak at normal speed),
    /// and the only one whose voices are averaged rather than matched to each sentence's length.
    case original = "5s"
    /// FluidAudio's 5 s graph (7.3 s in fact): about 90 tokens per pass.
    case fluidAudio5s = "fluid5s"
    /// FluidAudio's 10 s graph: about 130 tokens per pass.
    case fluidAudio10s = "fluid10s"
    /// FluidAudio's 15 s graph: about 200 tokens per pass, a whole sentence. A pass takes about a
    /// second on a Mac.
    case fluidAudio15s = "15s"

    /// Its name in settings.
    public var name: String {
        switch self {
        case .original: "Original 5 s"
        case .fluidAudio5s: "FluidAudio 5 s"
        case .fluidAudio10s: "FluidAudio 10 s"
        case .fluidAudio15s: "FluidAudio 15 s"
        }
    }

    /// About how much it downloads when nothing is stored yet, in megabytes. FluidAudio's models
    /// share their voices, so a second one adds about 325 MB.
    public var downloadMegabytes: Int {
        switch self {
        case .original: 335
        case .fluidAudio5s, .fluidAudio10s, .fluidAudio15s: 410
        }
    }
}

/// Text-to-speech with the Kokoro-82M models. In the app it is speech-swift's KokoroTTS, with the
/// models stored under Application Support. Tests use a fake that needs no model or network.
package protocol KokoroEngine: Sendable {
    /// Downloads `variant` if it isn't stored yet, then loads it, freeing any other model loaded
    /// first. Does nothing once it is loaded. `downloadProgress` gets the download's progress,
    /// from 0 to 1, and is not called when the model is already stored. It may be called on any
    /// thread.
    func load(_ variant: KokoroModelVariant, downloadProgress: @escaping @Sendable (Double) -> Void) async throws
    /// Frees the loaded model's memory. The model stays stored, so the next `load` loads it
    /// again without downloading.
    func unload() async
    /// Deletes every stored model, freeing the loaded one first, so the next `load` downloads
    /// again. Returns whether any of them was stored.
    func removeStoredModel() async throws -> Bool
    /// The words in the loaded model's English pronunciation dictionary, lowercased, for
    /// `KokoroAcronyms`. Empty if no model is loaded or the dictionary can't be read.
    func dictionaryWords() async -> Set<String>
    /// `text` spoken by `voice` (a Kokoro voice id such as `af_heart`) at `speed` (1 is normal),
    /// as 24 kHz mono samples. Throws if the model isn't loaded. Requests render one at a time;
    /// one whose task is cancelled before its turn throws `CancellationError` without rendering.
    func synthesize(_ text: String, voice: String, speed: Float) async throws -> [Float]
}

/// Where the Kokoro model is, for the settings screen.
public enum KokoroModelState: Sendable, Equatable {
    /// Not loaded: nothing has asked for it yet in this run, or no Kokoro voice is chosen. It
    /// may already be stored.
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

/// The model's state, and loading it while a Kokoro voice is chosen. One per voice loop. Once no
/// Kokoro voice has been chosen for `unusedLifetime`, it also deletes the stored model.
@MainActor
@Observable
final class KokoroModel {
    private static let log = Logger(label: "voice.kokoro")
    /// How long the model stays stored after the last Kokoro voice is unchosen: a day.
    static let unusedLifetime: TimeInterval = 24 * 60 * 60

    private(set) var state: KokoroModelState = .notLoaded
    /// The model to load. Changing it while a model is ready (or failed) loads the new one in
    /// its place. A load under way isn't cancelled, so a download isn't lost: the new model loads
    /// once it finishes.
    var variant = VoiceLoop.defaultKokoroModelVariant {
        didSet {
            guard variant != oldValue else { return }
            Self.log.notice("kokoro model chosen", ["model": variant.rawValue])
            switch state {
            case .ready, .failed:
                // Only while a Kokoro voice is chosen: `release()` leaves neither.
                state = .notLoaded
                dictionaryWords = []
                load()
            case .notLoaded, .loading, .downloading:
                break
            }
        }
    }
    /// The model's dictionary words (see `KokoroEngine.dictionaryWords()`) while it is ready, and
    /// empty otherwise.
    @ObservationIgnored private(set) var dictionaryWords: Set<String> = []
    @ObservationIgnored let engine: any KokoroEngine
    /// Whether a Kokoro voice is chosen: `load()` was called after the last `release()`.
    @ObservationIgnored private var isWanted = false
    /// The latest load, unload or removal. Each waits for the one before, so that an unload and
    /// the load after it reach the engine in order, and a removal never runs during a load.
    @ObservationIgnored private var lastEngineCall: Task<Void, Never>?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let readUnchosenSince: @MainActor () -> Date?
    @ObservationIgnored private let writeUnchosenSince: @MainActor (Date?) -> Void

    /// The engine is `environment.kokoro`. The environment's clock and record of when the last
    /// Kokoro voice was unchosen time the removal of the stored model.
    init(environment: VoiceEnvironment) {
        engine = environment.kokoro
        now = environment.now
        readUnchosenSince = environment.kokoroUnchosenSince
        writeUnchosenSince = environment.setKokoroUnchosenSince
    }

    /// When the last Kokoro voice was unchosen, kept across launches. Nil while one is chosen.
    private var unchosenSince: Date? {
        get { readUnchosenSince() }
        set { writeUnchosenSince(newValue) }
    }

    /// Downloads and loads `variant`, unless it is ready or already on its way. After a failure,
    /// tries again. While a Kokoro voice is chosen the stored models are never removed.
    func load() {
        isWanted = true
        unchosenSince = nil
        switch state {
        case .loading, .downloading, .ready:
            return
        case .notLoaded, .failed:
            break
        }
        state = .loading
        let started = ContinuousClock.now
        let requested = variant
        callEngine { [engine] in
            do {
                try await engine.load(requested) { progress in
                    Task { @MainActor in
                        self.downloaded(progress)
                    }
                }
            } catch {
                // Codes only: the downloader's messages name the model's folder.
                Self.log.error("kokoro model load failed", error.logCodes(["model": requested.rawValue]))
                if self.isWanted, self.variant != requested {
                    // Another model was chosen while this one loaded; it may load.
                    self.state = .notLoaded
                    self.load()
                } else {
                    // Settings offers a retry only while a Kokoro voice is chosen.
                    self.state = self.isWanted ? .failed : .notLoaded
                }
                return
            }
            // Before the check below, so no wait comes between it and `.ready`: a `release()`
            // during one would go unseen.
            let words = await engine.dictionaryWords()
            guard self.isWanted else {
                // A system voice was chosen while it loaded. The download is kept. The state
                // changes first, so a `load()` from now on queues a new load after the unload.
                self.state = .notLoaded
                Self.log.notice("kokoro model loaded after its voice was unchosen; releasing it")
                self.callEngine { [engine] in
                    await engine.unload()
                }
                return
            }
            guard self.variant == requested else {
                // Another model was chosen while this one loaded. Loading it frees this one.
                self.state = .notLoaded
                self.load()
                return
            }
            self.dictionaryWords = words
            self.state = .ready
            Self.log.notice("kokoro model ready", [
                "model": requested.rawValue,
                "ms": Int(started.duration(to: .now) / .milliseconds(1)),
            ])
        }
    }

    /// Frees the loaded model's memory, now that no Kokoro voice is chosen. A load in progress
    /// isn't cancelled, so a download isn't lost: the model is freed when it finishes, unless a
    /// Kokoro voice is chosen again by then. A failure is forgotten: settings offers a retry
    /// only while a Kokoro voice is chosen. The model stays stored for `unusedLifetime`, counted
    /// from the first release after a Kokoro voice was chosen: see `removeIfUnused()`.
    func release() {
        isWanted = false
        // Switching from one system voice to another doesn't restart the count.
        if unchosenSince == nil {
            unchosenSince = now()
        }
        switch state {
        case .ready:
            state = .notLoaded
            dictionaryWords = []
            Self.log.notice("kokoro model released")
            callEngine { [engine] in
                await engine.unload()
            }
        case .failed:
            state = .notLoaded
        case .notLoaded, .loading, .downloading:
            break
        }
    }

    /// Deletes the stored model if no Kokoro voice has been chosen for `unusedLifetime`. Without
    /// a record of when the last one was unchosen (a model downloaded before the record was
    /// kept), the count starts now instead. Does nothing while a Kokoro voice is chosen or the
    /// model is loading. The deletion waits for any unload still running, and is dropped if a
    /// Kokoro voice is chosen while it waits.
    func removeIfUnused() {
        guard hasGoneUnused() else { return }
        callEngine { [engine] in
            guard self.hasGoneUnused() else { return }
            do {
                if try await engine.removeStoredModel() {
                    Self.log.notice("kokoro model removed after going unused")
                }
            } catch {
                // Codes only: a file error's message names the model's folder.
                Self.log.error("removing the kokoro model failed", error.logCodes())
            }
        }
    }

    /// Whether no Kokoro voice has been chosen for `unusedLifetime` and nothing is loading.
    /// Starts the count if there is no record of when the last one was unchosen.
    private func hasGoneUnused() -> Bool {
        guard !isWanted, state == .notLoaded else { return false }
        guard let unchosenSince else {
            self.unchosenSince = now()
            return false
        }
        return now().timeIntervalSince(unchosenSince) >= Self.unusedLifetime
    }

    /// Runs `call` once the previous engine call has finished.
    private func callEngine(_ call: @escaping @MainActor () async -> Void) {
        let previous = lastEngineCall
        lastEngineCall = Task {
            await previous?.value
            await call()
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
