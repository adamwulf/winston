import Foundation
import Logging
import LogSupport

/// The pronunciation records' copy in iCloud's key-value store, which syncs it between Adam's
/// devices signed in to the same Apple Account. The iOS and Mac apps share one bundle ID, so
/// they share one store. Without the iCloud entitlement the store keeps it on this device only.
@MainActor
final class ICloudPronunciationStore: PronunciationSyncStore {
    private static let log = Logger(label: "app.pronunciations")
    /// The key the records are saved under, the same as in the user defaults.
    private static let key = "pronunciations"

    private let store = NSUbiquitousKeyValueStore.default
    private var observer: (any NSObjectProtocol)?

    init() {
        refresh()
    }

    isolated deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var data: Data? {
        store.data(forKey: Self.key)
    }

    func save(_ data: Data) {
        store.set(data, forKey: Self.key)
    }

    func refresh() {
        // False without the entitlement, say.
        if !store.synchronize() {
            Self.log.warning("iCloud key-value store unavailable; pronunciations stay on this device")
        }
    }

    func onExternalChange(_ handler: @escaping @MainActor @Sendable () -> Void) {
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { notification in
            let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            MainActor.assumeIsolated {
                if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
                    Self.log.error("synced pronunciations over iCloud's quota")
                }
                guard keys.contains(Self.key) else { return }
                Self.log.info("synced pronunciations changed", ["reason": Self.name(ofReason: reason)])
                handler()
            }
        }
    }

    /// The name of a change notification's reason, for the logs.
    private static func name(ofReason reason: Int?) -> String {
        switch reason {
        case NSUbiquitousKeyValueStoreServerChange?: "serverChange"
        case NSUbiquitousKeyValueStoreInitialSyncChange?: "initialSync"
        case NSUbiquitousKeyValueStoreQuotaViolationChange?: "quotaViolation"
        case NSUbiquitousKeyValueStoreAccountChange?: "accountChange"
        case let reason?: "\(reason)"
        case nil: "none"
        }
    }
}
