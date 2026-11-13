import Foundation
import Logging
import LogSupport
import Synchronization
import Testing

@Suite("Logger convenience overloads")
struct LoggerConvenienceTests {
    /// The `log.notice("msg", ["key": value])` sugar bridges a plain
    /// `[String: CustomStringConvertible]` bag into `Logger.Metadata`, rendering each value via
    /// its own `description`. Backend-agnostic: a recording handler captures what reaches it,
    /// with no `LoggingSystem.bootstrap`.
    @Test
    func metadataBagReachesTheHandlerAsDescriptions() throws {
        let recorder = MetadataRecorder()
        let logger = Logger(label: "test.convenience", factory: { _ in recorder })

        logger.notice("chats loaded", ["count": 3, "state": "ready", "chatID": 1_234_567_890_123 as Int64])

        let event = try #require(recorder.lastEvent)
        #expect(event.level == .notice)
        #expect(event.message == "chats loaded")
        #expect(event.metadata == ["count": "3", "state": "ready", "chatID": "1234567890123"])
    }

    @Test
    func everyLevelHasAnOverload() {
        let recorder = MetadataRecorder()
        let logger = Logger(label: "test.convenience", factory: { _ in recorder })
        let bag: [String: CustomStringConvertible] = ["key": 1]

        logger.trace("m", bag)
        logger.debug("m", bag)
        logger.info("m", bag)
        logger.notice("m", bag)
        logger.warning("m", bag)
        logger.error("m", bag)
        logger.critical("m", bag)

        #expect(recorder.levels == [.trace, .debug, .info, .notice, .warning, .error, .critical])
    }

    @Test
    func errorContextFitsTheBag() throws {
        let recorder = MetadataRecorder()
        let logger = Logger(label: "test.convenience", factory: { _ in recorder })
        let error = NSError(domain: "Test", code: 7)

        logger.error("send failed", error.logContext(["chatID": "42"]))

        let metadata = try #require(recorder.lastEvent?.metadata)
        #expect(metadata["chatID"] == "42")
        #expect(metadata["errorDomain"] == "Test")
        #expect(metadata["errorCode"] == "7")
    }
}

/// Records what reaches it, with metadata rendered to strings so assertions don't depend on
/// which `MetadataValue` case the bridge chose.
private final class MetadataRecorder: LogHandler, Sendable {
    struct Event: Sendable {
        let level: Logger.Level
        let message: String
        let metadata: [String: String]
    }

    private let events = Mutex<[Event]>([])

    var lastEvent: Event? { events.withLock { $0.last } }
    var levels: [Logger.Level] { events.withLock { $0.map(\.level) } }

    var metadata: Logger.Metadata {
        get { [:] }
        set {}
    }

    var logLevel: Logger.Level {
        get { .trace }
        set {}
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { nil }
        set {}
    }

    func log(event: LogEvent) {
        let recorded = Event(
            level: event.level,
            message: event.message.description,
            metadata: (event.metadata ?? [:]).mapValues(\.description)
        )
        events.withLock { $0.append(recorded) }
    }
}
