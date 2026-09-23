import TelemetryMacros

/// What the session middleware reports, as telemetry events.
///
/// ``AlulaSessionsModule`` contributes ``SessionMetrics/definitions``, so
/// an application with `AlulaTelemetryModule` reports these as the same
/// counters 0.33 did, under the same names. Attach to them directly for
/// anything else — an alert on store failures, a log line, a test:
///
/// ```swift
/// let failures = try await TelemetryTest.capture(SessionEvents.StoreFailed.self) {
///     _ = try await client.get("/")
/// }
/// #expect(failures.map(\.metadata.operation) == ["load"])
/// ```
public enum SessionEvents {
    /// A new session persisted for the first time.
    @TelemetryEvent("alula.sessions.created")
    public enum Created {}

    /// A session moved to a new id — sign-in, sign-out, `regenerate()`.
    @TelemetryEvent("alula.sessions.regenerated")
    public enum Regenerated {}

    /// The store threw. Each is a 503 to someone.
    @TelemetryEvent("alula.sessions.store_failed")
    public enum StoreFailed {
        public struct Metadata {
            /// `load`, `save` or `delete`.
            public var operation: String
        }
    }

    /// `revokeSessions(ownedBy:keeping:)` ended sessions.
    @TelemetryEvent("alula.sessions.revoked")
    public enum Revoked {
        public struct Measurements {
            /// How many ended.
            public var sessions: Int
        }
    }

    /// A revocation threw — including one against a store that cannot
    /// revoke.
    @TelemetryEvent("alula.sessions.revocation_failed")
    public enum RevocationFailed {}
}

/// The session counters: their names, and their definitions over
/// ``SessionEvents``. Dimensions are closed sets — an operation name —
/// never an id, a subject or a path, so a metrics backend's series count
/// stays fixed however many users there are.
public enum SessionMetrics {
    /// ``SessionEvents/Created``, counted.
    public static let created = "alula_sessions_created"
    /// ``SessionEvents/Regenerated``, counted.
    public static let regenerated = "alula_sessions_regenerated"
    /// ``SessionEvents/StoreFailed``, counted by `operation`.
    public static let storeFailures = "alula_sessions_store_failures"
    /// ``SessionEvents/Revoked``, counted by session, not by call.
    public static let revoked = "alula_sessions_revoked"
    /// ``SessionEvents/RevocationFailed``, counted.
    public static let revocationFailures = "alula_sessions_revocation_failures"

    /// What ``AlulaSessionsModule`` contributes to the reported metrics.
    public static let definitions: [TelemetryMetric] = [
        .counter(SessionEvents.Created.self),
        .counter(SessionEvents.Regenerated.self),
        .counter(
            SessionEvents.StoreFailed.self, name: "alula.sessions.store_failures",
            tags: \.operation),
        .sum(SessionEvents.Revoked.self, \.sessions, name: "alula.sessions.revoked"),
        .counter(SessionEvents.RevocationFailed.self, name: "alula.sessions.revocation_failures"),
    ]
}
