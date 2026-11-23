import Foundation
import Synchronization
import UniformTypeIdentifiers

extension ShareOutbox {
    public enum AddFailure: Error, Equatable {
        /// What was shared has no file or file content to send, such as a web link.
        case noFile
        /// A folder, as shared from Files: only files can be sent.
        case folder
    }

    /// Whether the share sheet's item holds something `add(_:)` can save: a file URL, or content
    /// of a file type. Not a web link alone, nor a folder's type.
    public static func canAdd(_ provider: NSItemProvider) -> Bool {
        provider.registeredTypeIdentifiers.compactMap { UTType($0) }.contains { type in
            type.conforms(to: .fileURL) || isContent(type)
        }
    }

    /// Files the share extension has copied into `Staging`, not yet handed to Winston: `publish`
    /// hands them over, `discard` drops them.
    public struct Staged: Sendable {
        /// Their batch folder in `Staging`.
        let batch: URL
        /// Each file's path in the batch, its item folder and its name, in the order shared.
        let paths: [String]

        public var count: Int {
            paths.count
        }
    }

    /// Copies what the share sheet handed over in `providers` into a batch folder in `Staging`,
    /// all or none, in the order given, each under its own name. Winston doesn't see them until
    /// `publish(_:)`.
    ///
    /// A shared file usually comes with its file URL and its content. The file URL comes first,
    /// as it keeps the file's name: the content's copy is named from the sharing app's suggested
    /// name, which it may not give, leaving one such as "Zip archive.zip". If the file can't be
    /// read, its content is copied instead. A file is read coordinated, so a file provider such as
    /// iCloud Drive can download it first, and off the caller's actor; content is copied on the
    /// provider's own queue. Throws `AddFailure.folder` for a folder, `AddFailure.noFile` for an
    /// item with neither, and what failed otherwise, leaving nothing behind.
    ///
    /// Cancelling the task, as Cancel in the sheet does, stops it before the next item and cancels
    /// the item provider's load under way; it then throws `CancellationError` or the provider's
    /// cancellation, leaving nothing behind.
    ///
    /// Runs on the caller's actor, the share extension's main actor, since `NSItemProvider` isn't
    /// Sendable.
    public nonisolated(nonsending) func stage(_ providers: [NSItemProvider]) async throws -> Staged {
        let batch = stagingFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        var paths: [String] = []
        do {
            for (index, provider) in providers.enumerated() {
                try Task.checkCancellation()
                // Named by its place, which `files()` lists them in.
                let item = String(format: "%03d", index)
                let itemFolder = batch.appending(path: item, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: itemFolder, withIntermediateDirectories: true)
                paths.append("\(item)/\(try await copy(provider, into: itemFolder))")
            }
            // A last item that came in after Cancel doesn't make it a share.
            try Task.checkCancellation()
        } catch {
            // Codes only: a file error's description names the file.
            Self.log.error("staging shared files failed", error.logCodes(["count": String(providers.count)]))
            Self.removeIfPresent(batch)
            throw error
        }
        Self.log.notice("shared files staged", ["count": paths.count])
        return Staged(batch: batch, paths: paths)
    }

    /// Hands staged files to Winston: moves their batch into `Outbox` in one rename, so Winston
    /// sees all of them or none. Returns where they are now.
    @discardableResult
    public func publish(_ staged: Staged) throws -> [URL] {
        let destination = outboxFolder.appending(path: staged.batch.lastPathComponent, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: outboxFolder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: staged.batch, to: destination)
        } catch {
            // Codes only: a file error's description names the file.
            Self.log.error("publishing shared files failed", error.logCodes(["count": String(staged.count)]))
            throw error
        }
        Self.log.notice("shared files published", ["count": staged.count])
        return staged.paths.map { destination.appending(path: $0) }
    }

    /// Removes staged files Adam cancelled.
    public func discard(_ staged: Staged) {
        Self.removeIfPresent(staged.batch)
        Self.log.notice("staged shared files discarded", ["count": staged.count])
    }

    /// The name to send a file under: the name the sharing app suggested, or else the loaded
    /// file's, with an extension for `type` if it hasn't one. Some apps suggest a name with no
    /// extension, such as "Screenshot 2026-11-20 at 2.35.00 PM", whose "00 PM" isn't one, and
    /// a loaded file can have a temporary one, such as "download.tmp" for a PDF: then the type's
    /// own extension is used.
    static func fileName(suggested: String?, loaded url: URL, type: UTType) -> String {
        let isForType = { (ext: String) in
            !ext.isEmpty && UTType(filenameExtension: ext)?.conforms(to: type) == true
        }
        let loadedExtension = isForType(url.pathExtension) ? url.pathExtension : type.preferredFilenameExtension
        if let suggested, !suggested.isEmpty {
            if isForType((suggested as NSString).pathExtension) {
                return safeFileName(suggested)
            }
            return safeFileName(loadedExtension.map { "\(suggested).\($0)" } ?? suggested)
        }
        if isForType(url.pathExtension) {
            return safeFileName(url.lastPathComponent)
        }
        let base = url.deletingPathExtension().lastPathComponent
        return safeFileName(loadedExtension.map { "\(base).\($0)" } ?? url.lastPathComponent)
    }

    /// File content, as opposed to a link to it: data that isn't a URL.
    private static func isContent(_ type: UTType) -> Bool {
        type.conforms(to: .data) && !type.conforms(to: .url)
    }

    /// Copies one shared item into `folder`, and returns the copy's name.
    private nonisolated(nonsending) func copy(_ provider: NSItemProvider, into folder: URL) async throws -> String {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        // Highest fidelity first.
        let contentType = types.first(where: Self.isContent)
        if types.contains(where: { $0.conforms(to: .fileURL) }) {
            do {
                let url = try await Self.loadFileURL(from: provider)
                // Not after Cancel: a coordinated copy can download a whole iCloud Drive file.
                try Task.checkCancellation()
                return try await Self.copyFile(at: url, into: folder)
            } catch AddFailure.folder {
                throw AddFailure.folder
            } catch {
                // A cancelled load isn't an unreadable file to fall back from.
                guard contentType != nil, !Task.isCancelled else { throw error }
                // Codes only: a file error's description names the file.
                Self.log.warning("shared file URL unreadable; copying its content instead", error.logCodes())
            }
        }
        guard let contentType else { throw AddFailure.noFile }
        return try await Self.copyContent(of: provider, type: contentType, into: folder)
    }

    /// Copies the file at a shared file URL into `folder`, under its own name, off the caller's
    /// actor, as `DocumentFiles.copyForSending` does in the app: security scoped, and coordinated.
    /// Cancelling the task cancels the coordinated read, as while an iCloud Drive file downloads.
    /// The copy itself, a clone on APFS, isn't stopped once begun.
    @concurrent
    private static func copyFile(at url: URL, into folder: URL) async throws -> String {
        // False for a URL that isn't security scoped, which is still readable if it's the process's own.
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { url.stopAccessingSecurityScopedResource() }
        }
        if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            throw AddFailure.folder
        }
        let name = safeFileName(url.lastPathComponent)
        let coordination = CoordinationCancellation()
        try await withTaskCancellationHandler {
            // Cancelled before the read began, it isn't started.
            try Task.checkCancellation()
            var coordinationError: NSError?
            var copyError: (any Error)?
            coordination.coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
                do {
                    try FileManager.default.copyItem(at: readableURL, to: folder.appending(path: name))
                } catch {
                    copyError = error
                }
            }
            if let error = coordinationError ?? copyError {
                throw error
            }
        } onCancel: {
            coordination.cancel()
        }
        return name
    }

    /// Copies the provider's content as `type` into `folder`. The file it loads is a temporary
    /// copy, removed once the completion handler returns, so it's copied in the handler, on the
    /// provider's queue.
    private nonisolated(nonsending) static func copyContent(
        of provider: NSItemProvider,
        type: UTType,
        into folder: URL
    ) async throws -> String {
        let suggestedName = provider.suggestedName
        let load = LoadCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                load.started(provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                    guard let url else {
                        continuation.resume(throwing: error ?? AddFailure.noFile)
                        return
                    }
                    continuation.resume(with: Result {
                        // A document kept as a folder, such as a package, can come this way too.
                        if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                            throw AddFailure.folder
                        }
                        let name = fileName(suggested: suggestedName, loaded: url, type: type)
                        try FileManager.default.copyItem(at: url, to: folder.appending(path: name))
                        return name
                    })
                })
            }
        } onCancel: {
            load.cancel()
        }
    }

    /// The provider's file URL. Cancelling the task cancels the load, as an app handing the file
    /// over can be slow to.
    private nonisolated(nonsending) static func loadFileURL(from provider: NSItemProvider) async throws -> URL {
        let load = LoadCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                load.started(provider.loadObject(ofClass: URL.self) { url, error in
                    if let url, url.isFileURL {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: error ?? AddFailure.noFile)
                    }
                })
            }
        } onCancel: {
            load.cancel()
        }
    }

    /// Removes `url` if it's there, logging a failure to.
    private static func removeIfPresent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        removeItem(at: url)
    }
}

/// A coordinated read, for the task's cancellation to cancel. `NSFileCoordinator.cancel()` may be
/// called from any thread, and stops a read still waiting, as for a download.
private final class CoordinationCancellation: @unchecked Sendable {
    let coordinator = NSFileCoordinator()

    func cancel() {
        coordinator.cancel()
    }
}

/// An item provider's load, for the task's cancellation to cancel, whether it comes before the
/// load has started or after.
private final class LoadCancellation: Sendable {
    private let state = Mutex<(progress: Progress?, isCancelled: Bool)>((nil, false))

    func started(_ progress: Progress) {
        let isCancelled = state.withLock { state in
            state.progress = progress
            return state.isCancelled
        }
        if isCancelled {
            progress.cancel()
        }
    }

    func cancel() {
        let progress = state.withLock { state in
            state.isCancelled = true
            return state.progress
        }
        progress?.cancel()
    }
}
