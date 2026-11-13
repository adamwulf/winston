import Foundation

/// Telegram API credentials, injected at build time from `App/Config/Secrets.xcconfig`
/// through `Info.plist`.
struct AppSecrets {
    let apiID: Int32
    let apiHash: String

    /// Nil when `Secrets.xcconfig` is missing or still has placeholder values.
    static func load(from bundle: Bundle = .main) -> AppSecrets? {
        guard
            let idString = bundle.object(forInfoDictionaryKey: "TelegramAPIID") as? String,
            let apiID = Int32(idString), apiID != 0,
            let apiHash = bundle.object(forInfoDictionaryKey: "TelegramAPIHash") as? String,
            !apiHash.isEmpty
        else { return nil }
        return AppSecrets(apiID: apiID, apiHash: apiHash)
    }
}
