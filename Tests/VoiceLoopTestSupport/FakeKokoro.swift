import Foundation
import Synchronization
import VoiceLoop

/// The Kokoro engine for tests: no model and no network. Its model "loads" when the test says
/// so, and it renders every sentence as the same 0.2 s tone, so a test can tell from
/// `OfflineAudio.playedFrames` whether a message came from Kokoro or from the system voice, and
/// from `OfflineAudio.playedZeroCrossings` how high it played.
package final class FakeKokoro: KokoroEngine {
    /// How long each rendered sentence sounds.
    package static let secondsPerSentence = 0.2
    /// The tone each sentence is rendered as, in Hz.
    package static let toneFrequency = 440.0

    /// What `load` does.
    package enum LoadBehavior: Sendable {
        /// Loads at once, without downloading: the model is already stored.
        case succeeds
        /// Fails at once with `FakeKokoroError.loadFailed`.
        case fails
        /// Waits until the test calls `finishLoading(succeeding:)`.
        case waits
    }

    /// One `synthesize` call.
    package struct Request: Equatable, Sendable {
        package let text: String
        package let voice: String
        package let speed: Float

        package init(text: String, voice: String, speed: Float) {
            self.text = text
            self.voice = voice
            self.speed = speed
        }
    }

    private struct State {
        var loadBehavior = LoadBehavior.succeeds
        var loadCalls = 0
        var loadedModels: [KokoroModelVariant] = []
        var loadedVoices: [String] = []
        var unloads = 0
        var removals = 0
        var loadedModel: KokoroModelVariant?
        var loadedVoice: String?
        /// Set by a `finishLoading(succeeding: true)` that came before any load reached the fake.
        var nextLoadSucceeds = false
        var isStored = false
        var waitingLoads: [(variant: KokoroModelVariant, voice: String, continuation: CheckedContinuation<Void, any Error>)] = []
        var downloadProgress: (@Sendable (Double) -> Void)?
        var stageChanged: (@Sendable (KokoroLoadStage) -> Void)?
        var requests: [Request] = []
        /// The `requests` index that fails, if any.
        var failingRequest: Int?
        var holdsSynthesis = false
        var heldSyntheses: [CheckedContinuation<Void, Never>] = []
        var dictionary: Set<String> = []
    }

    private let state = Mutex(State())

    package init() {}

    package var loadBehavior: LoadBehavior {
        get { state.withLock { $0.loadBehavior } }
        set { state.withLock { $0.loadBehavior = newValue } }
    }

    /// How many loads were needed for the requested model and voice.
    package var loads: Int { state.withLock { $0.loadedModels.count } }

    /// How many times the loop called `load`, counting calls that found the model and voice
    /// already loaded and did nothing.
    package var loadCalls: Int { state.withLock { $0.loadCalls } }

    /// The model each load asked for, oldest first.
    package var loadedModels: [KokoroModelVariant] { state.withLock { $0.loadedModels } }

    /// The voice each load asked for, oldest first.
    package var loadedVoices: [String] { state.withLock { $0.loadedVoices } }

    /// How many times the loop has freed the model.
    package var unloads: Int { state.withLock { $0.unloads } }

    /// How many times the loop has deleted the stored models.
    package var removals: Int { state.withLock { $0.removals } }

    /// The model in memory, if any.
    package var loadedModel: KokoroModelVariant? { state.withLock { $0.loadedModel } }

    /// Whether a model is in memory.
    package var isLoaded: Bool { loadedModel != nil }

    /// Whether a model is downloaded. A load that succeeds stores it; a test can store it
    /// beforehand, as an earlier launch would have.
    package var isStored: Bool {
        get { state.withLock { $0.isStored } }
        set { state.withLock { $0.isStored = newValue } }
    }

    /// Every sentence rendered or rendering, oldest first.
    package var requests: [Request] { state.withLock { $0.requests } }

    /// When set, the sentence with this index in `requests` fails to render.
    package var failingRequest: Int? {
        get { state.withLock { $0.failingRequest } }
        set { state.withLock { $0.failingRequest = newValue } }
    }

    /// While true, each sentence waits to finish rendering until `releaseSyntheses()`.
    package var holdsSynthesis: Bool {
        get { state.withLock { $0.holdsSynthesis } }
        set { state.withLock { $0.holdsSynthesis = newValue } }
    }

    /// What `dictionaryWords()` returns. Empty unless the test sets it, which leaves acronyms as
    /// written.
    package var dictionary: Set<String> {
        get { state.withLock { $0.dictionary } }
        set { state.withLock { $0.dictionary = newValue } }
    }

    /// Sentences waiting in `holdsSynthesis`.
    package var heldSyntheses: Int { state.withLock { $0.heldSyntheses.count } }

    /// Lets every held sentence finish rendering.
    package func releaseSyntheses() {
        let held = state.withLock { state in
            defer { state.heldSyntheses = [] }
            return state.heldSyntheses
        }
        for synthesis in held { synthesis.resume() }
    }

    /// Reports download progress to a waiting load.
    package func reportDownloadProgress(_ progress: Double) {
        state.withLock { $0.downloadProgress }?(progress)
    }

    /// Reports a stage to a waiting load.
    package func reportStage(_ stage: KokoroLoadStage) {
        state.withLock { $0.stageChanged }?(stage)
    }

    /// Ends the loads waiting in `.waits`. One that succeeds leaves its model loaded. Succeeding
    /// before the loop's load has reached the fake makes that load succeed at once.
    package func finishLoading(succeeding: Bool) {
        let waiting = state.withLock { state in
            defer { state.waitingLoads = [] }
            if succeeding {
                if let last = state.waitingLoads.last {
                    state.loadedModel = last.variant
                    state.loadedVoice = last.voice
                } else {
                    state.nextLoadSucceeds = true
                }
                state.isStored = true
            }
            return state.waitingLoads
        }
        for load in waiting {
            if succeeding {
                load.continuation.resume()
            } else {
                load.continuation.resume(throwing: FakeKokoroError.loadFailed)
            }
        }
    }

    package func load(
        _ variant: KokoroModelVariant,
        voice: String,
        downloadProgress: @escaping @Sendable (Double) -> Void,
        stageChanged: @escaping @Sendable (KokoroLoadStage) -> Void
    ) async throws {
        enum Outcome { case done, fails, waits }
        let outcome: Outcome = state.withLock { state in
            state.loadCalls += 1
            // A model that loads every voice has them all; the others have only the one asked for.
            if state.loadedModel == variant, variant.loadsEveryVoice || state.loadedVoice == voice {
                return .done
            }
            state.downloadProgress = downloadProgress
            state.stageChanged = stageChanged
            // As `KokoroEngine` promises: another model loaded is freed first.
            state.loadedModel = nil
            state.loadedVoice = nil
            let behavior = state.nextLoadSucceeds ? .succeeds : state.loadBehavior
            switch behavior {
            case .succeeds:
                state.nextLoadSucceeds = false
                state.loadedModels.append(variant)
                state.loadedVoices.append(voice)
                state.loadedModel = variant
                state.loadedVoice = voice
                state.isStored = true
                return .done
            case .fails:
                state.loadedModels.append(variant)
                state.loadedVoices.append(voice)
                return .fails
            case .waits:
                // Counted only once it waits, below, so a test that sees the load can finish it.
                return .waits
            }
        }
        switch outcome {
        case .done:
            return
        case .fails:
            throw FakeKokoroError.loadFailed
        case .waits:
            try await withCheckedThrowingContinuation { continuation in
                let finishedEarly = state.withLock { state in
                    state.loadedModels.append(variant)
                    state.loadedVoices.append(voice)
                    // `finishLoading(succeeding: true)` came before this load could wait.
                    if state.nextLoadSucceeds {
                        state.nextLoadSucceeds = false
                        state.loadedModel = variant
                        state.loadedVoice = voice
                        state.isStored = true
                        return true
                    }
                    state.waitingLoads.append((variant, voice, continuation))
                    return false
                }
                if finishedEarly { continuation.resume() }
            }
        }
    }

    package func unload() async {
        state.withLock { state in
            state.unloads += 1
            state.loadedModel = nil
            state.loadedVoice = nil
        }
    }

    package func removeStoredModel() async -> Bool {
        state.withLock { state in
            defer {
                state.loadedModel = nil
                state.loadedVoice = nil
                state.isStored = false
            }
            state.removals += 1
            return state.isStored
        }
    }

    package func dictionaryWords() async -> Set<String> {
        dictionary
    }

    package func synthesize(_ text: String, voice: String, speed: Float) async throws -> [Float] {
        // As `KokoroEngine` promises: a cancelled request renders nothing.
        try Task.checkCancellation()
        let (index, holds, isLoaded) = state.withLock { state in
            state.requests.append(Request(text: text, voice: voice, speed: speed))
            return (state.requests.count - 1, state.holdsSynthesis, state.loadedModel != nil)
        }
        guard isLoaded else { throw FakeKokoroError.notLoaded }
        if holds {
            await withCheckedContinuation { continuation in
                state.withLock { $0.heldSyntheses.append(continuation) }
            }
        }
        if state.withLock({ $0.failingRequest }) == index {
            throw FakeKokoroError.synthesisFailed
        }
        let sampleRate = 24_000.0
        return (0..<Int(Self.secondsPerSentence * sampleRate)).map { frame in
            Float(0.25 * sin(2 * .pi * Self.toneFrequency * Double(frame) / sampleRate))
        }
    }
}

package enum FakeKokoroError: Error {
    case loadFailed
    case notLoaded
    case synthesisFailed
}
