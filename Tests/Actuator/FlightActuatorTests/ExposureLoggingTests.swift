import FlightCore
import Logging
import Synchronization
import Testing

@testable import FlightActuator

/// Collects what a module logged, without bootstrapping the global system.
private final class Capture: Sendable {
    struct Entry: Sendable {
        let level: Logger.Level
        let message: String
    }
    private let entries = Mutex<[Entry]>([])

    func record(_ level: Logger.Level, _ message: String) {
        entries.withLock { $0.append(Entry(level: level, message: message)) }
    }
    var all: [Entry] { entries.withLock { $0 } }

    /// A logger writing into this capture.
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

@Suite("Exposure is announced at startup")
struct ExposureLoggingTests {

    @Test("full outside a development environment warns, and says what it discloses")
    func fullOutsideDevelopmentWarns() {
        // The only way to reach this is an explicit FLIGHT_ACTUATOR_EXPOSURE,
        // and the dashboard is unauthenticated wherever it is on. Nothing
        // used to record that a deployment had started publishing it.
        let capture = Capture()
        _ = ActuatorModule(
            environment: FlightEnvironment("production"), exposure: .full,
            logger: capture.logger)

        let warnings = capture.all.filter { $0.level == .warning }
        #expect(warnings.count == 1)
        let text = warnings.first?.message ?? ""
        #expect(text.contains("unauthenticated"))
        #expect(text.contains("FLIGHT_ACTUATOR_EXPOSURE"))
    }

    @Test("full outside development, behind authentication, is news rather than a warning")
    func fullBehindAuthenticationIsInfo() {
        let capture = Capture()
        _ = ActuatorModule(
            environment: FlightEnvironment("production"), exposure: .full,
            dashboardAccess: ActuatorDashboardAccess(
                pipelines: [.authenticated], roles: ["operator"]),
            logger: capture.logger)
        #expect(capture.all.filter { $0.level == .warning }.isEmpty)
        #expect(
            capture.all.contains {
                $0.level == .info && $0.message.contains("behind authentication")
            })
    }

    @Test("a dashboard lane that establishes no identity still warns")
    func unauthenticatedLaneStillWarns() {
        // Naming a lane is not the same as requiring someone: an "audit" lane
        // with no roles lets anybody through, and the warning has to say so.
        let capture = Capture()
        _ = ActuatorModule(
            environment: FlightEnvironment("production"), exposure: .full,
            dashboardAccess: ActuatorDashboardAccess(pipelines: ["audit"]),
            logger: capture.logger)
        #expect(capture.all.filter { $0.level == .warning }.count == 1)
    }

    @Test("full in a development environment is ordinary news, not a warning")
    func fullInDevelopmentIsInfo() {
        let capture = Capture()
        _ = ActuatorModule(environment: .dev, exposure: .full, logger: capture.logger)
        #expect(capture.all.filter { $0.level == .warning }.isEmpty)
        #expect(capture.all.contains { $0.level == .info })
    }

    @Test("health_only says so, and says no topology is disclosed")
    func healthOnlyIsAnnounced() {
        let capture = Capture()
        _ = ActuatorModule(
            environment: FlightEnvironment("production"), exposure: .healthOnly,
            logger: capture.logger)
        let info = capture.all.filter { $0.level == .info }
        #expect(info.count == 1)
        #expect(info.first?.message.contains("no topology") == true)
    }

    @Test("disabled is announced too — silence is not a report")
    func disabledIsAnnounced() {
        let capture = Capture()
        _ = ActuatorModule(environment: .dev, exposure: .disabled, logger: capture.logger)
        #expect(capture.all.contains { $0.message.contains("disabled") })
    }

    @Test("the composition path announces exactly once")
    func configurationPathAnnouncesOnce() throws {
        // `init(configuration:)` delegates to `init(processEnvironment:)` and
        // then calls `installController` a second time to apply the format.
        // Announcing from there would have logged twice for every app that
        // composes normally — which is every app.
        let capture = Capture()
        _ = try ActuatorModule(
            configuration: Configuration(values: [:]), logger: capture.logger)
        #expect(capture.all.count == 1, "announced \(capture.all.count) times")
    }
}
