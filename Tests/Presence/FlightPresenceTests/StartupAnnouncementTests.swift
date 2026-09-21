import FlightPubSub
import Logging
import Synchronization
import Testing

@testable import FlightPresence

/// Collects what the service logged, without bootstrapping the global system.
private final class Capture: Sendable {
    private let entries = Mutex<[(level: Logger.Level, message: String)]>([])

    func record(_ level: Logger.Level, _ message: String) {
        entries.withLock { $0.append((level, message)) }
    }
    var all: [(level: Logger.Level, message: String)] { entries.withLock { $0 } }
    var logger: Logger { Logger(label: "test") { _ in Handler(capture: self) } }

    private struct Handler: LogHandler {
        let capture: Capture
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
            capture.record(level, message.description)
        }
    }
}

/// `Docs/presence.md` promises the degraded mode is "logged at **warning**
/// level so nobody discovers this from a bug report". Nothing held that
/// promise: a refactor dropping it to `.info` would have lost the whole point
/// — loudness — without failing anything.
@Suite("Failure-detection mode is announced at startup", .timeLimit(.minutes(1)))
struct StartupAnnouncementTests {

    private func announce(mode: PresenceMode) async -> Capture {
        let capture = Capture()
        let configuration = PresenceConfiguration(
            heartbeatInterval: .milliseconds(50), downAfter: .milliseconds(200))
        let local = LocalPubSub()
        let tracker = PresenceTracker(
            replica: PresenceReplicaID(name: "n1", boot: "b1"),
            mode: mode, configuration: configuration,
            localBus: local, gossipBus: local, logger: capture.logger)
        let service = PresenceService(
            tracker: tracker, pubsub: local, monitor: nil,
            configuration: configuration, logger: capture.logger)

        // `logStartup` is the first thing `run()` does; everything after it
        // is a loop or a park, so start it and take the announcement.
        let task = Task { try? await service.run() }
        try? await Task.sleep(for: .milliseconds(120))
        task.cancel()
        _ = await task.value
        return capture
    }

    @Test("degraded heartbeat-expiry is a warning, and says why it is degraded")
    func degradedIsAWarning() async {
        let capture = await announce(mode: .heartbeatExpiry)
        let warnings = capture.all.filter { $0.level == .warning }
        #expect(warnings.count == 1)
        let text = warnings.first?.message ?? ""
        #expect(text.contains("DEGRADED"))
        // The operator needs the consequence and the fix, not just the label.
        #expect(text.contains("down-after"))
        #expect(text.contains("membership-aware"))
    }

    @Test("the intended multi-node mode is ordinary news")
    func membershipIsInfo() async {
        let capture = await announce(mode: .membership)
        #expect(capture.all.filter { $0.level == .warning }.isEmpty)
        #expect(capture.all.contains { $0.level == .info })
    }

    @Test("single-node says so rather than staying silent")
    func singleNodeIsAnnounced() async {
        let capture = await announce(mode: .singleNode)
        #expect(capture.all.contains { $0.message.contains("single-node") })
        #expect(capture.all.filter { $0.level == .warning }.isEmpty)
    }
}
