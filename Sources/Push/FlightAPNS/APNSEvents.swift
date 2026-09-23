import FlightTelemetry

/// What the APNs client reports, as telemetry events.
///
/// ``FlightAPNSModule`` contributes ``APNSMetrics/definitions``, so an
/// application with `FlightTelemetryModule` reports these as the counters
/// 0.33 did, under the same names — and a send-latency distribution.
public enum APNSEvents {
    /// One per `send`, after the one protocol retry.
    @TelemetryEvent("flight.apns.send")
    public enum Send {
        public struct Measurements {
            /// The whole call, provider token and retry included.
            public var duration: Duration
        }
        public struct Metadata {
            /// `delivered`, or Apple's reason string (`Unregistered`,
            /// `TooManyRequests`, …, or this package's own
            /// `flight:transport` and friends) — a closed set, never a
            /// device token.
            public var outcome: String
        }
    }

    /// A provider token signed. Apple refuses updates more often than every
    /// 20 minutes (`TooManyProviderTokenUpdates`); a rate climbing past that
    /// is the early warning.
    @TelemetryEvent("flight.apns.provider_token_minted")
    public enum ProviderTokenMinted {}

    static func sent(_ outcome: String, since start: ContinuousClock.Instant?) {
        Telemetry.emit(Send.self) {
            (.init(duration: start.map { .now - $0 } ?? .zero), .init(outcome: outcome))
        }
    }
}

/// The APNs counters: their names, and their definitions over
/// ``APNSEvents``.
public enum APNSMetrics {
    /// ``APNSEvents/Send``, counted by `outcome`.
    public static let sends = "flight_apns_sends"
    /// ``APNSEvents/Send``'s duration, by `outcome`.
    public static let sendDuration = "flight_apns_send_duration"
    /// ``APNSEvents/ProviderTokenMinted``, counted.
    public static let providerTokensMinted = "flight_apns_provider_tokens_minted"

    /// What ``FlightAPNSModule`` contributes to the reported metrics.
    public static let definitions: [TelemetryMetric] = [
        .counter(APNSEvents.Send.self, name: "flight.apns.sends", tags: \.outcome),
        .distribution(APNSEvents.Send.self, \.duration, unit: .milliseconds, tags: \.outcome),
        .counter(APNSEvents.ProviderTokenMinted.self, name: "flight.apns.provider_tokens_minted"),
    ]
}
