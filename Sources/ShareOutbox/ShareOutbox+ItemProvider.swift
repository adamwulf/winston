import Foundation
import UniformTypeIdentifiers

extension ShareOutbox {
    public enum AddFailure: Error {
        /// The shared item has no file or file content to send, such as a web link.
        case noFile
    }

    /// Copies what the share sheet handed over in `provider` into the outbox for the agent with
    /// `agentID`: the file its file URL names, under the file's own name, or else its content in
    /// the richest file type it has. Throws `AddFailure.noFile` when it has neither.
    ///
    /// A shared file usually comes with both. The content's copy is named after the sharing app's
    /// suggested name, which it may not give, leaving a name such as "Zip archive.zip", so the
    /// file URL comes first. If it can't be read, the content is copied instead.
    ///
    /// Runs on the caller's actor, since `NSItemProvider` isn't Sendable: the share extension's
    /// main actor. The content's copy is made on the provider's own queue.
    @discardableResult
    public nonisolated(nonsending) func add(_ provider: NSItemProvider, for agentID: Int64) async throws -> OutboxItem {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        // Highest fidelity first. A URL is data too, but not a file's content.
        let contentType = types.first { $0.conforms(to: .data) && !$0.conforms(to: .url) }
        if types.contains(where: { $0.conforms(to: .fileURL) }) {
            do {
                return try addFile(at: await Self.loadFileURL(from: provider), for: agentID)
            } catch {
                guard contentType != nil else { throw error }
                Self.log.warning("shared file URL unreadable; copying its content instead", error.logCodes())
            }
        }
        if let contentType {
            return try await addFileRepresentation(of: provider, type: contentType, suggestedName: provider.suggestedName, for: agentID)
        }
        throw AddFailure.noFile
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
        return name
    }

    /// Copies the provider's content as `type` into the outbox. The file it loads is a temporary
    /// copy that is removed once the completion handler returns, so it's copied in the handler.
    private nonisolated(nonsending) func addFileRepresentation(
        of provider: NSItemProvider,
        type: UTType,
        suggestedName: String?,
        for agentID: Int64
    ) async throws -> OutboxItem {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else {
                    continuation.resume(throwing: error ?? AddFailure.noFile)
                    return
                }
                continuation.resume(with: Result {
                    try add(
                        fileAt: url,
                        named: Self.fileName(suggested: suggestedName, loaded: url, type: type),
                        typeIdentifier: type.identifier,
                        for: agentID
                    )
                })
            }
        }
    }

    /// Copies the file at a shared file URL into the outbox, under its own name.
    private func addFile(at url: URL, for agentID: Int64) throws -> OutboxItem {
        // False for a URL that isn't security scoped, which is still readable if it's the process's own.
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { url.stopAccessingSecurityScopedResource() }
        }
        let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType ?? .data
        return try add(fileAt: url, named: url.lastPathComponent, typeIdentifier: type.identifier, for: agentID)
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
}
