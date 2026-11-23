import Foundation
import Testing

/// Holds a coordinated write on a file until `release()`, so a coordinated read of it, as
/// `DocumentFiles.copyForSending` makes, waits meanwhile: as for an iCloud Drive file still
/// downloading.
final class WriteHold: Sendable {
    private let released = DispatchSemaphore(value: 0)

    init(on url: URL) throws {
        let started = DispatchSemaphore(value: 0)
        let released = released
        DispatchQueue.global().async {
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &error) { _ in
                started.signal()
                released.wait()
            }
        }
        try #require(started.wait(timeout: .now() + 10) == .success)
    }

    func release() {
        released.signal()
    }
}
