import AlulaPubSub
import Foundation
import Logging
import ServiceLifecycle
import ServiceLifecycleTestKit
import Synchronization
import Testing

/// Relay #46: presence's leave, published on the way out, reached a Valkey
/// client that had already stopped, and every clean stop logged a warning.
@Suite("A broadcast that fails while stopping is not a warning")
struct ShutdownBroadcastTests {
    struct Stopped: DistributedPubSubAdapter {
        struct ClientShutdown: Error {}
        func broadcast(_ message: Message) async throws { throw ClientShutdown() }
        func incoming() -> AsyncStream<Message> { AsyncStream { _ in } }
    }

    final class Levels: @unchecked Sendable {
        let seen = Mutex<[Logger.Level]>([])
        var logger: Logger { Logger(label: "test") { _ in Handler(levels: self) } }
        struct Handler: LogHandler {
            let levels: Levels
            var metadata: Logger.Metadata = [:]
            var logLevel: Logger.Level = .trace
            subscript(metadataKey key: String) -> Logger.Metadata.Value? {
                get { metadata[key] }
                set { metadata[key] = newValue }
            }
            func log(
                level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
                source: String, file: String, function: String, line: UInt
            ) {
                if message.description.contains("distributed broadcast failed") {
                    levels.seen.withLock { $0.append(level) }
                }
            }
        }
    }

    @Test("while serving it warns; while shutting down gracefully it is debug")
    func levelFollowsLifecycle() async {
        let levels = Levels()
        let pubsub = ClusteredPubSub(
            local: LocalPubSub(), adapter: Stopped(), nodeID: "n", logger: levels.logger)
        await pubsub.publish(Message(topic: "room:1", payload: Data()))
        await testGracefulShutdown { trigger in
            trigger.triggerGracefulShutdown()
            await pubsub.publish(Message(topic: "room:1", payload: Data()))
        }
        #expect(levels.seen.withLock { $0 } == [.warning, .debug])
    }
}
