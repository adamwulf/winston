import CoreML
import Foundation
@preconcurrency import KokoroTTS
import Logging
import LogSupport
import Synchronization

// The real Kokoro engine behind `KokoroEngine`: speech-swift's KokoroTTS. Like
// `LiveVoiceEnvironment.swift`, the unit tests don't load its models: it downloads 245-335 MB a
// model. `KokoroRealModelTests` runs it when the default model, soniqo's, has already been
// downloaded.

/// speech-swift's `KokoroTTSModel`, downloaded into `directory` and loaded there, one
/// `KokoroModelVariant` at a time. The model isn't `Sendable`, so it stays inside this actor, which
/// runs on a queue of its own: a sentence takes up to a second to render, too long to hold a Swift
/// concurrency thread.
package actor LiveKokoro: KokoroEngine {
    private static let log = Logger(label: "voice.kokoro.live")

    /// Holds the models' folders and, for each model, the marker saying its download finished.
    private let directory: URL
    private let queue = DispatchSerialQueue(label: "voice.kokoro")
    /// The loaded model, and which one it is.
    private var loaded: (variant: KokoroModelVariant, model: KokoroTTSModel)?
    /// The models whose placement has been logged in this launch.
    private var placementLogged: Set<KokoroModelVariant> = []

    package nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// `directory` is created if needed, and excluded from backup: the models can be downloaded
    /// again.
    package init(directory: URL) {
        self.directory = directory
    }

    /// `variant`'s files, as KokoroTTS lays them out. FluidAudio's models share a folder, so
    /// their voices download once; soniqo's model has a folder of its own, since KokoroTTS
    /// loads every voice file it finds, and the two repositories' voices have different formats.
    private func modelFolder(_ variant: KokoroModelVariant) -> URL {
        directory.appending(path: variant.folderName, directoryHint: .isDirectory)
    }

    /// Present once `variant` has downloaded completely and loaded.
    private func downloadedMarker(_ variant: KokoroModelVariant) -> URL {
        directory.appending(path: "\(variant.markerName).downloaded", directoryHint: .notDirectory)
    }

    package func load(
        _ variant: KokoroModelVariant,
        voice: String,
        downloadProgress: @escaping @Sendable (Double) -> Void,
        stageChanged: @escaping @Sendable (KokoroLoadStage) -> Void
    ) async throws {
        if let loaded, loaded.variant == variant, loaded.model.availableVoices.contains(voice) { return }
        // Freed first, so the two models are never in memory together.
        loaded = nil
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var store = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try store.setResourceValues(values)

        let folder = modelFolder(variant)
        let marker = downloadedMarker(variant)
        // A finished download loads without the network if the voice is stored too. Otherwise,
        // KokoroTTS asks Hugging Face for the file list and downloads the missing files.
        if canLoadOffline(variant, voice: voice) {
            Self.log.notice("loading stored kokoro model", ["model": variant.rawValue, "voice": voice])
            do {
                loaded = (variant, try await Self.load(
                    variant, voice: voice, from: folder, offline: true, downloadProgress: nil, stageChanged: stageChanged
                ))
                notePlacement(variant, in: folder)
                return
            } catch {
                // Codes only: KokoroTTS's messages name the folder.
                Self.log.warning(
                    "stored kokoro model failed to load; downloading it again",
                    error.logCodes(["model": variant.rawValue])
                )
                try? FileManager.default.removeItem(at: marker)
            }
        }
        // Downloads only the files that are missing or incomplete.
        Self.log.notice("downloading kokoro model", ["model": variant.rawValue, "voice": voice])
        let downloaded = try await Self.load(
            variant, voice: voice, from: folder, offline: false, downloadProgress: downloadProgress, stageChanged: stageChanged
        )
        // Before the model counts as loaded: if the marker can't be written (the disk is full),
        // the load fails, and a retry downloads nothing more but writes the marker again.
        try Data().write(to: marker)
        loaded = (variant, downloaded)
        notePlacement(variant, in: folder)
    }

    /// A model marker records the model's download; an offline load also needs the chosen voice.
    func canLoadOffline(_ variant: KokoroModelVariant, voice: String) -> Bool {
        FileManager.default.fileExists(atPath: downloadedMarker(variant).path)
            && FileManager.default.fileExists(atPath: modelFolder(variant).appending(path: "voices/\(voice).json").path)
    }

    /// One KokoroTTS load of `variant`, which logs each stage it reaches and how long it took, and
    /// passes each stage to `stageChanged`.
    private static func load(
        _ variant: KokoroModelVariant,
        voice: String,
        from folder: URL,
        offline: Bool,
        downloadProgress: (@Sendable (Double) -> Void)?,
        stageChanged: @escaping @Sendable (KokoroLoadStage) -> Void
    ) async throws -> KokoroTTSModel {
        let stages = LoadStages(variant: variant)
        do {
            let model = try await KokoroTTSModel.fromPretrained(
                modelId: variant.modelId,
                modelFile: variant.modelFile,
                voiceFilter: variant.voiceFilter(for: voice),
                cacheDir: folder,
                offlineMode: offline,
                computeUnits: variant.computeUnits
            ) { fraction, message in
                if let stage = stages.report(message) {
                    stageChanged(stage)
                }
                // KokoroTTS reports the download as 0...0.7 of its progress, then loading.
                downloadProgress?(min(fraction / 0.7, 1))
            }
            log.notice("kokoro tts load finished", stages.metadata(["offline": offline, "ms": stages.elapsedMilliseconds]))
            return model
        } catch {
            // Codes only: KokoroTTS's messages name the folder.
            log.warning(
                "kokoro tts load failed",
                error.logCodes(["model": variant.rawValue, "offline": String(offline), "ms": String(stages.elapsedMilliseconds)])
            )
            throw error
        }
    }

    /// Logs one KokoroTTS load's stages, each once, as its progress handler reports them: it
    /// names the stage with each call, download fractions included. The handler may run on any
    /// thread.
    private final class LoadStages: Sendable {
        let variant: KokoroModelVariant
        /// When the load began.
        private let started = ContinuousClock.now
        /// KokoroTTS's latest message.
        private let message = Mutex<String?>(nil)

        init(variant: KokoroModelVariant) {
            self.variant = variant
        }

        /// Since the load began.
        var elapsedMilliseconds: Int {
            Int(started.duration(to: .now) / .milliseconds(1))
        }

        /// Logs `message`, the progress handler's, unless it is the one before. Returns the stage
        /// it names, if it is new and one of `KokoroLoadStage`'s.
        func report(_ message: String) -> KokoroLoadStage? {
            let isNew = self.message.withLock { current in
                defer { current = message }
                return current != message
            }
            guard isNew else { return nil }
            let stage = KokoroLoadStage(kokoroTTSMessage: message)
            // A message KokoroTTS didn't send when this was written is logged as it is.
            LiveKokoro.log.notice("kokoro load stage", metadata(["stage": stage?.rawValue ?? message, "ms": elapsedMilliseconds]))
            return stage
        }

        /// `fields` with the model and, on iOS, the memory the app may still use.
        func metadata(_ fields: [String: CustomStringConvertible]) -> [String: CustomStringConvertible] {
            var metadata = fields
            metadata["model"] = variant.rawValue
            if let megabytes = AvailableMemory.megabytes {
                metadata["availableMB"] = megabytes
            }
            return metadata
        }
    }

    /// Logs where Core ML runs `variant`, just loaded from `folder`, once per model per launch.
    /// In the background, so speaking doesn't wait for it. A model limited to the CPU runs there
    /// and needs no compute plan, which matters: reading the masked models' plans (38,000 to 55,000
    /// operations) took two to four and a half minutes on a Mac, and held up loading another model
    /// meanwhile.
    private func notePlacement(_ variant: KokoroModelVariant, in folder: URL) {
        guard placementLogged.insert(variant).inserted else { return }
        guard variant.computeUnits != .cpuOnly else {
            Self.log.notice("kokoro model placement", ["model": variant.rawValue, "computeUnits": "cpuOnly"])
            return
        }
        let model = folder.appending(path: "\(variant.modelFile).mlmodelc", directoryHint: .isDirectory)
        Task.detached(priority: .background) {
            await Self.logPlacement(of: model, variant: variant)
        }
    }

    /// Logs how many of `model`'s operations Core ML prefers to run on the CPU, the GPU and the
    /// Neural Engine, and each one's share of the operations' estimated cost, which says where
    /// the time goes. From the model's compute plan, under the same compute units it loads with.
    private static func logPlacement(of model: URL, variant: KokoroModelVariant) async {
        let started = ContinuousClock.now
        let configuration = MLModelConfiguration()
        configuration.computeUnits = variant.computeUnits
        let plan: MLComputePlan
        do {
            plan = try await MLComputePlan.load(contentsOf: model, configuration: configuration)
        } catch {
            // Codes only: Core ML's messages name the model's folder.
            log.warning("kokoro model placement unknown", error.logCodes(["model": variant.rawValue]))
            return
        }
        guard case .program(let program) = plan.modelStructure, let main = program.functions["main"] else {
            log.warning("kokoro model placement unknown: not an ML program", ["model": variant.rawValue])
            return
        }
        var operations: [String: Int] = [:]
        var costs: [String: Double] = [:]
        var blocks = [main.block]
        while let block = blocks.popLast() {
            for operation in block.operations {
                blocks.append(contentsOf: operation.blocks)
                // Constants and the like run nowhere, and have no device.
                guard let usage = plan.deviceUsage(for: operation) else { continue }
                let device = deviceName(usage.preferred)
                operations[device, default: 0] += 1
                costs[device, default: 0] += plan.estimatedCost(of: operation)?.weight ?? 0
            }
        }
        let totalCost = costs.values.reduce(0, +)
        var metadata: [String: CustomStringConvertible] = [
            "model": variant.rawValue,
            "ms": Int(started.duration(to: .now) / .milliseconds(1)),
        ]
        for device in Set(operations.keys).union(["cpu", "gpu", "ane"]) {
            metadata["\(device)Ops"] = operations[device, default: 0]
            let share = totalCost > 0 ? costs[device, default: 0] / totalCost : 0
            metadata["\(device)Cost"] = "\(Int((share * 100).rounded()))%"
        }
        log.notice("kokoro model placement", metadata)
    }

    /// `device` as the logs name it.
    private static func deviceName(_ device: MLComputeDevice) -> String {
        switch device {
        case .cpu: "cpu"
        case .gpu: "gpu"
        case .neuralEngine: "ane"
        @unknown default: "other"
        }
    }

    package func unload() {
        loaded = nil
    }

    package func removeStoredModel() throws -> Bool {
        loaded = nil
        let manager = FileManager.default
        // The markers first: if removing a folder fails partway, what is left counts as an
        // unfinished download, which the next load completes. Each folder once, though models
        // share it.
        let variants = KokoroModelVariant.allCases
        let folders = variants.map(modelFolder).reduce(into: [URL]()) { folders, folder in
            if !folders.contains(folder) { folders.append(folder) }
        }
        let stored = (variants.map(downloadedMarker) + folders)
            .filter { manager.fileExists(atPath: $0.path) }
        for item in stored {
            try manager.removeItem(at: item)
        }
        return !stored.isEmpty
    }

    /// The loaded model's dictionary words: see `dictionaryWords(in:)`.
    package func dictionaryWords() -> Set<String> {
        guard let variant = loaded?.variant else { return [] }
        return Self.dictionaryWords(in: modelFolder(variant))
    }

    /// The words KokoroTTS finds in the American English dictionaries it downloads into each
    /// model's `folder` (its British voices use them too). It looks words up in lowercase, and has
    /// each key that starts with a capital in lowercase too, so it finds those and the lowercase
    /// keys, but not a key such as "dB": "DB" isn't one of its words. Empty if either dictionary
    /// can't be read.
    static func dictionaryWords(in folder: URL) -> Set<String> {
        var words = Set<String>()
        for file in ["us_gold.json", "us_silver.json"] {
            do {
                let data = try Data(contentsOf: folder.appending(path: file, directoryHint: .notDirectory))
                guard let entries = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    Self.log.warning("kokoro dictionary isn't an object; acronyms are left as written", ["file": file])
                    return []
                }
                for key in entries.keys {
                    let lowercased = key.lowercased()
                    if key == lowercased || key.first?.isUppercase == true {
                        words.insert(lowercased)
                    }
                }
            } catch {
                // Codes only: a file error's message names the model's folder.
                Self.log.warning("kokoro dictionary unreadable; acronyms are left as written", error.logCodes(["file": file]))
                return []
            }
        }
        return words
    }

    package func synthesize(_ text: String, voice: String, speed: Float) async throws -> [Float] {
        // A request waits here while an earlier one renders. If its speech was stopped meanwhile
        // (a newer preview, say), rendering it would only delay the next one.
        try Task.checkCancellation()
        guard let model = loaded?.model else { throw KokoroEngineError.notLoaded }
        return try model.synthesize(text: text, voice: voice, speed: speed)
    }
}

package enum KokoroEngineError: Error {
    /// `synthesize` was called before `load` finished.
    case notLoaded
}

/// Where each model comes from, where it is stored, and what it runs on.
extension KokoroModelVariant {
    /// Its folder in `LiveKokoro`'s directory. The models from one repository share a folder, so
    /// its voices and dictionaries download once. FluidAudio's folder keeps the name it had when it
    /// held only the 15 s model, so a download stored then is still found.
    fileprivate var folderName: String {
        switch self {
        case .soniqo5s: "Kokoro-82M-CoreML"
        case .masked5s, .masked10s, .masked15s: "Kokoro-82M-Masked"
        case .fluidAudio5s, .fluidAudio10s, .fluidAudio15s: "Kokoro-82M-15s"
        }
    }

    /// Its marker in `LiveKokoro`'s directory, without `.downloaded`. Each model has one, since
    /// models share folders.
    fileprivate var markerName: String {
        switch self {
        case .soniqo5s: "Kokoro-82M-CoreML"
        case .masked5s, .masked10s, .masked15s: "Kokoro-82M-Masked.\(modelFile)"
        case .fluidAudio5s: "Kokoro-82M-15s.kokoro_21_5s"
        case .fluidAudio10s: "Kokoro-82M-15s.kokoro_21_10s"
        case .fluidAudio15s: "Kokoro-82M-15s"
        }
    }

    /// Its Hugging Face repository.
    fileprivate var modelId: String {
        switch self {
        case .soniqo5s: KokoroTTSModel.defaultModelId
        case .masked5s, .masked10s, .masked15s: "milestonemade/Kokoro-82M-CoreML-Masked"
        case .fluidAudio5s, .fluidAudio10s, .fluidAudio15s: "FluidInference/kokoro-82m-coreml"
        }
    }

    /// Its end-to-end graph in the repository, without `.mlmodelc`.
    fileprivate var modelFile: String {
        switch self {
        case .soniqo5s: KokoroTTSModel.defaultModelFile
        case .masked5s: "kokoro_masked_5s_fp16"
        case .masked10s: "kokoro_masked_10s_fp16"
        case .masked15s: "kokoro_masked_15s_fp16"
        case .fluidAudio5s: "kokoro_21_5s"
        case .fluidAudio10s: "kokoro_21_10s"
        case .fluidAudio15s: "kokoro_21_15s"
        }
    }

    /// The voices it downloads and loads with `voice` chosen: every voice for a model that
    /// `loadsEveryVoice` (soniqo's, whose voices are small), as it always has; the others take
    /// only the chosen voice (2.7 MB).
    fileprivate func voiceFilter(for voice: String) -> [String]? {
        loadsEveryVoice ? nil : [voice]
    }

    /// What it may run on. Never `.all`, the default: on macOS 27 compiling these models for the
    /// GPU aborts the process in MPSGraph ("invalid axis (122) for input of rank 2"), which can't
    /// be caught. The masked fp16 models run on the CPU only: allowing the Neural Engine makes
    /// their first load compile for it for over an hour on a Mac, and each pass is then about 5
    /// times slower. The others may use the Neural Engine, though the placement log shows the
    /// soniqo's runs entirely on the CPU anyway. Core ML picks each operation's device;
    /// `logPlacement` logs it.
    fileprivate var computeUnits: MLComputeUnits {
        switch self {
        case .masked5s, .masked10s, .masked15s: .cpuOnly
        case .soniqo5s, .fluidAudio5s, .fluidAudio10s, .fluidAudio15s: .cpuAndNeuralEngine
        }
    }
}

extension KokoroLoadStage {
    /// The stage KokoroTTS's `fromPretrained` names in `message`, the second argument of its
    /// progress handler. Nil for "Model loaded", which ends the load, and for any message it
    /// didn't send when this was written.
    fileprivate init?(kokoroTTSMessage message: String) {
        switch message {
        case "Downloading model...": self = .downloading
        case "Loading vocabulary...": self = .vocabulary
        case "Loading G2P models...": self = .g2p
        case "Loading voice embeddings...": self = .voices
        case "Loading CoreML model...": self = .coreML
        case "Warming up...": self = .warmingUp
        default: return nil
        }
    }
}
