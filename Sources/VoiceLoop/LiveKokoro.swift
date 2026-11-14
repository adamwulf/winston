import CoreML
import Foundation
@preconcurrency import KokoroTTS
import Logging
import LogSupport

// The real Kokoro engine behind `KokoroEngine`: speech-swift's KokoroTTS. Like
// `LiveVoiceEnvironment.swift`, the unit tests don't run this file: it downloads a 335 or 410 MB
// model. `KokoroRealModelTests` runs it when the 15 s model has already been downloaded.

/// speech-swift's `KokoroTTSModel`, downloaded into `directory` and loaded there, one
/// `KokoroModelVariant` at a time. The model isn't `Sendable`, so it stays inside this actor, which
/// runs on a queue of its own: a sentence takes up to a second to render, too long to hold a Swift
/// concurrency thread.
package actor LiveKokoro: KokoroEngine {
    private static let log = Logger(label: "voice.kokoro.live")

    /// Holds each model's folder and the marker saying its download finished.
    private let directory: URL
    private let queue = DispatchSerialQueue(label: "voice.kokoro")
    /// The loaded model, and which one it is.
    private var loaded: (variant: KokoroModelVariant, model: KokoroTTSModel)?

    package nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// `directory` is created if needed, and excluded from backup: the models can be downloaded
    /// again.
    package init(directory: URL) {
        self.directory = directory
    }

    /// `variant`'s files, as KokoroTTS lays them out. Each model has a folder of its own:
    /// KokoroTTS loads every voice file it finds, and the two models' voices have different
    /// formats.
    private func modelFolder(_ variant: KokoroModelVariant) -> URL {
        directory.appending(path: variant.folderName, directoryHint: .isDirectory)
    }

    /// Present once `variant` has downloaded completely and loaded.
    private func downloadedMarker(_ variant: KokoroModelVariant) -> URL {
        directory.appending(path: "\(variant.folderName).downloaded", directoryHint: .notDirectory)
    }

    package func load(_ variant: KokoroModelVariant, downloadProgress: @escaping @Sendable (Double) -> Void) async throws {
        if loaded?.variant == variant { return }
        // Freed first, so the two models are never in memory together.
        loaded = nil
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var store = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try store.setResourceValues(values)

        let folder = modelFolder(variant)
        let marker = downloadedMarker(variant)
        // A finished download loads without the network. Without the marker, KokoroTTS asks
        // Hugging Face for the file list first, and while offline retries for about two minutes.
        if FileManager.default.fileExists(atPath: marker.path) {
            do {
                loaded = (variant, try await Self.load(variant, from: folder, offline: true, downloadProgress: nil))
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
        let downloaded = try await Self.load(variant, from: folder, offline: false, downloadProgress: downloadProgress)
        // Before the model counts as loaded: if the marker can't be written (the disk is full),
        // the load fails, and a retry downloads nothing more but writes the marker again.
        try Data().write(to: marker)
        loaded = (variant, downloaded)
    }

    private static func load(
        _ variant: KokoroModelVariant,
        from folder: URL,
        offline: Bool,
        downloadProgress: (@Sendable (Double) -> Void)?
    ) async throws -> KokoroTTSModel {
        try await KokoroTTSModel.fromPretrained(
            modelId: variant.modelId,
            modelFile: variant.modelFile,
            voiceFilter: variant.voiceFilter,
            cacheDir: folder,
            offlineMode: offline,
            // Not `.all`, the default: on macOS 27 compiling these models for the GPU aborts the
            // process in MPSGraph ("invalid axis (122) for input of rank 2"), which can't be
            // caught. The Neural Engine and CPU work.
            computeUnits: .cpuAndNeuralEngine
        ) { fraction, _ in
            // KokoroTTS reports the download as 0...0.7 of its progress, then loading.
            downloadProgress?(min(fraction / 0.7, 1))
        }
    }

    package func unload() {
        loaded = nil
    }

    package func removeStoredModel() throws -> Bool {
        loaded = nil
        let manager = FileManager.default
        // The markers first: if removing a folder fails partway, what is left counts as an
        // unfinished download, which the next load completes.
        let variants = KokoroModelVariant.allCases
        let stored = (variants.map(downloadedMarker) + variants.map(modelFolder))
            .filter { manager.fileExists(atPath: $0.path) }
        for item in stored {
            try manager.removeItem(at: item)
        }
        return !stored.isEmpty
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

/// Where each model comes from and is stored.
extension KokoroModelVariant {
    /// Its folder in `LiveKokoro`'s directory, next to its `.downloaded` marker.
    fileprivate var folderName: String {
        switch self {
        case .fiveSecond: "Kokoro-82M-CoreML"
        case .fifteenSecond: "Kokoro-82M-15s"
        }
    }

    /// Its Hugging Face repository.
    fileprivate var modelId: String {
        switch self {
        case .fiveSecond: KokoroTTSModel.defaultModelId
        case .fifteenSecond: "FluidInference/kokoro-82m-coreml"
        }
    }

    /// Its end-to-end graph in the repository, without `.mlmodelc`.
    fileprivate var modelFile: String {
        switch self {
        case .fiveSecond: KokoroTTSModel.defaultModelFile
        case .fifteenSecond: "kokoro_21_15s"
        }
    }

    /// The voices it downloads and loads. The 5 s repository's voices are small, so it takes
    /// them all, as it always has; the 15 s repository's are 2.7 MB each, so it takes only the
    /// American and British English voices `KokoroCatalog` offers.
    fileprivate var voiceFilter: [String]? {
        switch self {
        case .fiveSecond: nil
        case .fifteenSecond: ["a*", "b*"]
        }
    }
}
