import Foundation

/// Telegram API credentials, injected at build time from `App/Config/Secrets.xcconfig`
/// through `Info.plist`.
public struct AppSecrets: Sendable, Equatable {
    public let apiID: Int32
    public let apiHash: String

    public init(apiID: Int32, apiHash: String) {
        self.apiID = apiID
        self.apiHash = apiHash
    }

    /// Nil when `Secrets.xcconfig` is missing or still has placeholder values.
    public static func load(from bundle: Bundle = .main) -> AppSecrets? {
        guard
            let idString = bundle.object(forInfoDictionaryKey: "TelegramAPIID") as? String,
            let apiID = Int32(idString), apiID != 0,
            let apiHash = bundle.object(forInfoDictionaryKey: "TelegramAPIHash") as? String,
            !apiHash.isEmpty
        else { return nil }
        return AppSecrets(apiID: apiID, apiHash: apiHash)
    }
}
