import Foundation
import WinstonCore

/// The sync store for tests, in place of iCloud's key-value store: one device's copy, in
/// memory. `receive(_:)` is another device's write arriving.
@MainActor
final class FakePronunciationSyncStore: PronunciationSyncStore {
    private(set) var data: Data?
    /// Everything this device saved, oldest first.
    private(set) var saves: [Data] = []
    private var handlers: [@MainActor @Sendable () -> Void] = []

    /// A store that already holds `data`, as one another device saved to before this launch.
    init(data: Data? = nil) {
        self.data = data
    }

    func save(_ data: Data) {
        self.data = data
        saves.append(data)
    }

    func onExternalChange(_ handler: @escaping @MainActor @Sendable () -> Void) {
        handlers.append(handler)
    }

    /// Another device's write arriving: `data` takes the place of what is here, and each model
    /// on this store hears of it.
    func receive(_ data: Data?) {
        self.data = data
        for handler in handlers {
            handler()
        }
    }
}
