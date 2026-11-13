import CoreML
import Foundation
@preconcurrency import KokoroTTS
import Logging
import LogSupport

// The real Kokoro engine behind `KokoroEngine`: speech-swift's KokoroTTS. Like
// `LiveVoiceEnvironment.swift`, the unit tests don't run this file: it downloads a 335 MB model.
// `KokoroRealModelTests` runs it when the model has already been downloaded.

/// speech-swift's `KokoroTTSModel`, downloaded into `directory` and loaded there. The model isn't
/// `Sendable`, so it stays inside this actor, which runs on a queue of its own: a sentence takes
/// a few hundred milliseconds to render, too long to hold a Swift concurrency thread.
package actor LiveKokoro: KokoroEngine {
    private static let log = Logger(label: "voice.kokoro.live")

    /// Holds the model folder and the marker saying its download finished.
    private let directory: URL
    private let queue = DispatchSerialQueue(label: "voice.kokoro")
    private var model: KokoroTTSModel?

    package nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// `directory` is created if needed, and excluded from backup: the model can be downloaded
    /// again.
    package init(directory: URL) {
        self.directory = directory
    }

    /// The model's files, as KokoroTTS lays them out.
    private var modelFolder: URL {
        directory.appending(path: "Kokoro-82M-CoreML", directoryHint: .isDirectory)
    }

    /// Present once the model has downloaded completely and loaded.
    private var downloadedMarker: URL {
        directory.appending(path: "Kokoro-82M-CoreML.downloaded", directoryHint: .notDirectory)
    }

    package func load(downloadProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard model == nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var store = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try store.setResourceValues(values)

        // A finished download loads without the network. Without the marker, KokoroTTS asks
        // Hugging Face for the file list first, and while offline retries for about two minutes.
        if FileManager.default.fileExists(atPath: downloadedMarker.path) {
            do {
                model = try await Self.load(from: modelFolder, offline: true, downloadProgress: nil)
                return
            } catch {
                // Codes only: KokoroTTS's messages name the folder.
                Self.log.warning("stored kokoro model failed to load; downloading it again", error.logCodes())
                try? FileManager.default.removeItem(at: downloadedMarker)
            }
        }
        // Downloads only the files that are missing or incomplete.
        model = try await Self.load(from: modelFolder, offline: false, downloadProgress: downloadProgress)
        FileManager.default.createFile(atPath: downloadedMarker.path, contents: nil)
    }

    private static func load(
        from folder: URL,
        offline: Bool,
        downloadProgress: (@Sendable (Double) -> Void)?
    ) async throws -> KokoroTTSModel {
        try await KokoroTTSModel.fromPretrained(
            cacheDir: folder,
            offlineMode: offline,
            // Not `.all`, the default: on macOS 27 compiling this model for the GPU aborts the
            // process in MPSGraph ("invalid axis (122) for input of rank 2"), which can't be
            // caught. The Neural Engine and CPU work.
            computeUnits: .cpuAndNeuralEngine
        ) { fraction, _ in
            // KokoroTTS reports the download as 0...0.7 of its progress, then loading.
            downloadProgress?(min(fraction / 0.7, 1))
        }
    }

    package func unload() {
        model = nil
    }

    package func synthesize(_ text: String, voice: String, speed: Float) async throws -> [Float] {
        // A request waits here while an earlier one renders. If its speech was stopped meanwhile
        // (a newer preview, say), rendering it would only delay the next one.
        try Task.checkCancellation()
        guard let model else { throw KokoroEngineError.notLoaded }
        return try model.synthesize(text: text, voice: voice, speed: speed)
    }
}

package enum KokoroEngineError: Error {
    /// `synthesize` was called before `load` finished.
    case notLoaded
}
