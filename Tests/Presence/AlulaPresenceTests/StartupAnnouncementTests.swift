import AlulaPubSub
import Logging
import Synchronization
import Testing

@testable import AlulaPresence

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

    private func announce(mode: PresenceMode, downAfterIsExplicit: Bool = false) async -> Capture {
        let capture = Capture()
        var configuration = PresenceConfiguration(
            heartbeatInterval: .milliseconds(50), downAfter: .milliseconds(200))
        configuration.downAfterIsExplicit = downAfterIsExplicit
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

    @Test("heartbeat expiry with a defaulted down-after is a warning that names the setting")
    func degradedIsAWarning() async {
        let capture = await announce(mode: .heartbeatExpiry)
        let warnings = capture.all.filter { $0.level == .warning }
        #expect(warnings.count == 1)
        let text = warnings.first?.message ?? ""
        // The consequence, and the one thing an operator can do about it
        // with what ships (Relay #40: it recommended an adapter nobody has).
        #expect(text.contains("heartbeat expiry"))
        #expect(text.contains("presence.down-after-seconds"))
        #expect(!text.contains("use the membership-aware adapter"))
    }

    /// Once down-after is chosen, the delayed leave is a decision, and a
    /// warning on every start of every node only teaches people to skip it.
    @Test("heartbeat expiry with down-after chosen is info")
    func chosenDownAfterIsInfo() async {
        let capture = await announce(mode: .heartbeatExpiry, downAfterIsExplicit: true)
        #expect(capture.all.filter { $0.level == .warning }.isEmpty)
        #expect(capture.all.contains { $0.level == .info && $0.message.contains("heartbeat expiry") })
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
