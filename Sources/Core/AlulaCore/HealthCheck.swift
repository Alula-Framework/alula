/// A dependency this process needs in order to serve traffic, asked on demand.
///
/// Module health says whether a module's *service* is up. That is not the same
/// as whether what it talks to is answering: a Postgres pool's service can run
/// happily against a database that went away an hour ago. A `HealthCheck` is
/// that second question, asked by the readiness probe.
///
/// Checks are contributions: any module holding a `[HealthCheck]` property
/// contributes it, and Actuator's readiness probe runs them all. A datasource
/// module contributes one wrapping its pool's `ping()`; an application adds
/// its own the same way.
///
/// ```swift
/// struct AppModule: AlulaModule {
///     let healthChecks: [HealthCheck] = [
///         HealthCheck(name: "payments-api") { try await payments.ping() },
///     ]
/// }
/// ```
///
/// Checks decide **readiness only**. A failing dependency takes the process
/// out of rotation; it never fails liveness, because restarting a pod does not
/// bring a database back and a whole fleet restarting at once makes the outage
/// worse.
public struct HealthCheck: Sendable {
    /// Shown in logs when the check changes state. Never in a probe response:
    /// the probe is unauthenticated, and dependency names are topology.
    public let name: String

    /// How long one check may take before it counts as failed.
    public let timeout: Duration

    private let probe: @Sendable () async throws -> Void

    /// - Parameters:
    ///   - name: What the check is of, for logs.
    ///   - timeout: How long one run may take before it counts as failed.
    ///   - probe: Throws when the dependency is not answering.
    public init(
        name: String,
        timeout: Duration = .seconds(2),
        _ probe: @escaping @Sendable () async throws -> Void
    ) {
        self.name = name
        self.timeout = timeout
        self.probe = probe
    }

    /// Runs the probe under `timeout`. A timeout, a thrown error and a
    /// cancelled caller all come back as a failure rather than propagating.
    public func run() async -> HealthCheckResult {
        await withTaskGroup(of: HealthCheckResult?.self) { group in
            group.addTask {
                do {
                    try await probe()
                    return .passed
                } catch {
                    return .failed(String(describing: error))
                }
            }
            group.addTask { [timeout] in
                do {
                    try await Task.sleep(for: timeout)
                    return .failed("timed out after \(timeout)")
                } catch {
                    return nil
                }
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failed("cancelled")
        }
    }
}

/// One run of a ``HealthCheck``.
public enum HealthCheckResult: Sendable, Equatable {
    case passed
    /// Why it failed — for logs, not for the probe response.
    case failed(String)

    public var passed: Bool { self == .passed }
}
