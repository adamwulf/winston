import Foundation
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

    /// Saves what the share sheet handed over in `providers` to the outbox for Winston, all or
    /// none, in the order given, and returns the saved files. Each goes under its own name.
    ///
    /// A shared file usually comes with its file URL and its content. The file URL comes first,
    /// as it keeps the file's name: the content's copy is named from the sharing app's suggested
    /// name, which it may not give, leaving one such as "Zip archive.zip". If the file can't be
    /// read, its content is copied instead. A file is read coordinated, so a file provider such as
    /// iCloud Drive can download it first, and off the caller's actor; content is copied on the
    /// provider's own queue. Throws `AddFailure.folder` for a folder, `AddFailure.noFile` for an
    /// item with neither, and what failed otherwise, leaving nothing in the outbox.
    ///
    /// Runs on the caller's actor, the share extension's main actor, since `NSItemProvider` isn't
    /// Sendable.
    @discardableResult
    public nonisolated(nonsending) func add(_ providers: [NSItemProvider]) async throws -> [URL] {
        let batch = stagingFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        var saved: [URL] = []
        do {
            var staged: [(folder: URL, name: String)] = []
            for provider in providers {
                let itemFolder = batch.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: itemFolder, withIntermediateDirectories: true)
                staged.append((itemFolder, try await stage(provider, in: itemFolder)))
            }
            try FileManager.default.createDirectory(at: outboxFolder, withIntermediateDirectories: true)
            // Each move is one rename, so Winston sees each file whole or not at all.
            for item in staged {
                let destination = outboxFolder.appending(path: item.folder.lastPathComponent, directoryHint: .isDirectory)
                try FileManager.default.moveItem(at: item.folder, to: destination)
                saved.append(destination.appending(path: item.name))
            }
        } catch {
            // Codes only: a file error's description names the file.
            Self.log.error("saving shared files failed", error.logCodes(["count": String(providers.count)]))
            remove(saved)
            Self.removeIfPresent(batch)
            throw error
        }
        Self.removeIfPresent(batch)
        Self.log.notice("shared files saved", ["count": saved.count])
        return saved
    }

    /// The name to send a file under: the name the sharing app suggested, or else the loaded
    /// file's, with an extension for `type` if it has none. Some apps suggest a name with no
    /// extension, such as "Screenshot 2026-11-20 at 2.35.00 PM", whose "00 PM" isn't one.
    static func fileName(suggested: String?, loaded url: URL, type: UTType) -> String {
        var name = suggested.flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
        let ext = (name as NSString).pathExtension
        let hasExtensionForType = !ext.isEmpty && UTType(filenameExtension: ext)?.conforms(to: type) == true
        if !hasExtensionForType, let typeExtension = url.pathExtension.isEmpty ? type.preferredFilenameExtension : url.pathExtension {
            name += ".\(typeExtension)"
        }
        return safeFileName(name)
    }

    /// File content, as opposed to a link to it: data that isn't a URL.
    private static func isContent(_ type: UTType) -> Bool {
        type.conforms(to: .data) && !type.conforms(to: .url)
    }

    /// Copies one shared item into `folder`, and returns the copy's name.
    private nonisolated(nonsending) func stage(_ provider: NSItemProvider, in folder: URL) async throws -> String {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        // Highest fidelity first.
        let contentType = types.first(where: Self.isContent)
        if types.contains(where: { $0.conforms(to: .fileURL) }) {
            do {
                return try await Self.copyFile(at: Self.loadFileURL(from: provider), into: folder)
            } catch AddFailure.folder {
                throw AddFailure.folder
            } catch {
                guard contentType != nil else { throw error }
                // Codes only: a file error's description names the file.
                Self.log.warning("shared file URL unreadable; copying its content instead", error.logCodes())
            }
        }
        guard let contentType else { throw AddFailure.noFile }
        return try await Self.copyContent(of: provider, type: contentType, into: folder)
    }

    /// Copies the file at a shared file URL into `folder`, under its own name, off the caller's
    /// actor, as `DocumentFiles.copyForSending` does in the app: security scoped, and coordinated.
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
        var coordinationError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            do {
                try FileManager.default.copyItem(at: readableURL, to: folder.appending(path: name))
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError {
            throw error
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
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else {
                    continuation.resume(throwing: error ?? AddFailure.noFile)
                    return
                }
                continuation.resume(with: Result {
                    let name = fileName(suggested: suggestedName, loaded: url, type: type)
                    try FileManager.default.copyItem(at: url, to: folder.appending(path: name))
                    return name
                })
            }
        }
    }

    private nonisolated(nonsending) static func loadFileURL(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url, url.isFileURL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? AddFailure.noFile)
                }
            }
        }
    }

    /// Removes `url` if it's there, logging a failure to.
    private static func removeIfPresent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        removeItem(at: url)
    }
}
