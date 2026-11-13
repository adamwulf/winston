import Foundation
import Logging

extension Error {
    /// The log fields that explain this error, merged over `extra`.
    /// `localizedDescription` alone can lose them: a Swift enum with no
    /// `LocalizedError` conformance renders as "The operation couldn’t be
    /// completed. (Module.Type error 0.)", with its case and payload gone.
    ///
    /// Developer-facing: these fields name types and codes, so they must never
    /// reach a user-visible string. Use `localizedDescription` there.
    public func logContext(_ extra: [String: String] = [:]) -> [String: String] {
        var context = logCodes(extra)
        context["error"] = localizedDescription
        // Only an enum is reflected. NSError and the Foundation wrappers around
        // it (CocoaError, URLError) would print their userInfo, which can hold
        // file paths and URLs. An enum whose payload can hold user data must
        // define a `debugDescription` that leaves it out.
        if Mirror(reflecting: self).displayStyle == .enum {
            context["errorCase"] = String(reflecting: self)
        }
        return context
    }

    /// Only the domain and code of this error and its underlying error, merged
    /// over `extra`. Use this when the description may hold user data, such as an
    /// error about a file the user chose (Foundation's description names the file).
    public func logCodes(_ extra: [String: String] = [:]) -> [String: String] {
        let nsError = self as NSError
        var context = extra
        context["errorDomain"] = nsError.domain
        context["errorCode"] = String(nsError.code)
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            context["underlyingDomain"] = underlying.domain
            context["underlyingCode"] = String(underlying.code)
        }
        return context
    }

    /// `logContext` as swift-log metadata, for swift-log's own `metadata:` API.
    public func logMetadata(_ extra: Logger.Metadata = [:]) -> Logger.Metadata {
        extra.merging(logContext().mapValues { .string($0) }) { _, errorField in errorField }
    }
}
