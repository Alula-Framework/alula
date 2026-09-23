import FlightTelemetry

/// What the session middleware reports, as telemetry events.
///
/// ``FlightSessionsModule`` contributes ``SessionMetrics/definitions``, so
/// an application with `FlightTelemetryModule` reports these as the same
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
    @TelemetryEvent("flight.sessions.created")
    public enum Created {}

    /// A session moved to a new id — sign-in, sign-out, `regenerate()`.
    @TelemetryEvent("flight.sessions.regenerated")
    public enum Regenerated {}

    /// The store threw. Each is a 503 to someone.
    @TelemetryEvent("flight.sessions.store_failed")
    public enum StoreFailed {
        public struct Metadata {
            /// `load`, `save` or `delete`.
            public var operation: String
        }
    }

    /// `revokeSessions(ownedBy:keeping:)` ended sessions.
    @TelemetryEvent("flight.sessions.revoked")
    public enum Revoked {
        public struct Measurements {
            /// How many ended.
            public var sessions: Int
        }
    }

    /// A revocation threw — including one against a store that cannot
    /// revoke.
    @TelemetryEvent("flight.sessions.revocation_failed")
    public enum RevocationFailed {}
}

/// The session counters: their names, and their definitions over
/// ``SessionEvents``. Dimensions are closed sets — an operation name —
/// never an id, a subject or a path, so a metrics backend's series count
/// stays fixed however many users there are.
public enum SessionMetrics {
    /// ``SessionEvents/Created``, counted.
    public static let created = "flight_sessions_created"
    /// ``SessionEvents/Regenerated``, counted.
    public static let regenerated = "flight_sessions_regenerated"
    /// ``SessionEvents/StoreFailed``, counted by `operation`.
    public static let storeFailures = "flight_sessions_store_failures"
    /// ``SessionEvents/Revoked``, counted by session, not by call.
    public static let revoked = "flight_sessions_revoked"
    /// ``SessionEvents/RevocationFailed``, counted.
    public static let revocationFailures = "flight_sessions_revocation_failures"

    /// What ``FlightSessionsModule`` contributes to the reported metrics.
    public static let definitions: [TelemetryMetric] = [
        .counter(SessionEvents.Created.self),
        .counter(SessionEvents.Regenerated.self),
        .counter(
            SessionEvents.StoreFailed.self, name: "flight.sessions.store_failures",
            tags: \.operation),
        .sum(SessionEvents.Revoked.self, \.sessions, name: "flight.sessions.revoked"),
        .counter(SessionEvents.RevocationFailed.self, name: "flight.sessions.revocation_failures"),
    ]
}
