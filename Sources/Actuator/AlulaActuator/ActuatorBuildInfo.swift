import AlulaCore
import Foundation

/// What `/actuator/info` reports: which build is running, and since when.
///
/// ```yaml
/// app:
///   name: Shop
///   version: 1.4.2          # or ALULA_APP_VERSION, set by the image build
///   build:
///     commit: 3f9c2a1
///     time: 2026-09-24T21:00:00Z
/// ```
///
/// Every value is optional; an unset one is left out. The endpoint is
/// published where the dashboard is, behind the same roles: a precise
/// version tells an attacker which advisories apply.
public struct ActuatorBuildInfo: Sendable, Equatable {
    public var name: String?
    public var version: String?
    public var commit: String?
    public var buildTime: String?
    public var startedAt: Date

    public init(
        name: String? = nil, version: String? = nil, commit: String? = nil,
        buildTime: String? = nil, startedAt: Date = Date()
    ) {
        self.name = name
        self.version = version
        self.commit = commit
        self.buildTime = buildTime
        self.startedAt = startedAt
    }

    /// Reads `app.name`, `app.version`, `app.build.commit` and `app.build.time`.
    public init(configuration: Configuration, startedAt: Date = Date()) throws {
        self.init(
            name: try configuration.getIfPresent("app.name", as: String.self),
            version: try configuration.getIfPresent("app.version", as: String.self),
            commit: try configuration.getIfPresent("app.build.commit", as: String.self),
            buildTime: try configuration.getIfPresent("app.build.time", as: String.self),
            startedAt: startedAt)
    }

    /// The wire shape, with uptime measured at `now`.
    struct Document: Encodable {
        let name: String?
        let version: String?
        let commit: String?
        let buildTime: String?
        let environment: String
        let startedAt: String
        let uptimeSeconds: Int
    }

    func document(environment: AlulaEnvironment, now: Date = Date()) -> Document {
        Document(
            name: name, version: version, commit: commit, buildTime: buildTime,
            environment: environment.rawValue,
            startedAt: startedAt.formatted(.iso8601),
            uptimeSeconds: max(0, Int(now.timeIntervalSince(startedAt))))
    }
}
