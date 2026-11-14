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
        var loadedModels: [KokoroModelVariant] = []
        var unloads = 0
        var removals = 0
        var loadedModel: KokoroModelVariant?
        /// Set by a `finishLoading(succeeding: true)` that came before any load reached the fake.
        var nextLoadSucceeds = false
        var isStored = false
        var waitingLoads: [(variant: KokoroModelVariant, continuation: CheckedContinuation<Void, any Error>)] = []
        var downloadProgress: (@Sendable (Double) -> Void)?
        var requests: [Request] = []
        /// The `requests` index that fails, if any.
        var failingRequest: Int?
        var holdsSynthesis = false
        var heldSyntheses: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    package init() {}

    package var loadBehavior: LoadBehavior {
        get { state.withLock { $0.loadBehavior } }
        set { state.withLock { $0.loadBehavior = newValue } }
    }

    /// How many times the loop has asked for a model.
    package var loads: Int { state.withLock { $0.loadedModels.count } }

    /// The model each load asked for, oldest first.
    package var loadedModels: [KokoroModelVariant] { state.withLock { $0.loadedModels } }

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

    /// Ends the loads waiting in `.waits`. One that succeeds leaves its model loaded. Succeeding
    /// before the loop's load has reached the fake makes that load succeed at once.
    package func finishLoading(succeeding: Bool) {
        let waiting = state.withLock { state in
            defer { state.waitingLoads = [] }
            if succeeding {
                if let last = state.waitingLoads.last {
                    state.loadedModel = last.variant
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

    package func load(_ variant: KokoroModelVariant, downloadProgress: @escaping @Sendable (Double) -> Void) async throws {
        let behavior = state.withLock { state in
            state.loadedModels.append(variant)
            state.downloadProgress = downloadProgress
            if state.loadedModel == variant || state.nextLoadSucceeds {
                state.nextLoadSucceeds = false
                return LoadBehavior.succeeds
            }
            // As `KokoroEngine` promises: another model loaded is freed first.
            state.loadedModel = nil
            return state.loadBehavior
        }
        switch behavior {
        case .succeeds:
            state.withLock { state in
                state.loadedModel = variant
                state.isStored = true
            }
        case .fails:
            throw FakeKokoroError.loadFailed
        case .waits:
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.waitingLoads.append((variant, continuation)) }
            }
        }
    }

    package func unload() async {
        state.withLock { state in
            state.unloads += 1
            state.loadedModel = nil
        }
    }

    package func removeStoredModel() async -> Bool {
        state.withLock { state in
            defer {
                state.loadedModel = nil
                state.isStored = false
            }
            state.removals += 1
            return state.isStored
        }
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
