import TelemetryMacros

/// What the HTTP server reports, as telemetry events.
///
/// ``AlulaWebModule`` contributes ``HTTPMetrics/definitions``, so an
/// application with `AlulaTelemetryModule` reports request counts and
/// latency by route. This is a plain event, not a span: the request's
/// server span is already a tracing span (see ``Dispatch``), and a second
/// one would trace every request twice.
public enum HTTPEvents {
    /// A request answered — emitted once the response is built, before its
    /// body is written.
    @TelemetryEvent("alula.http.request")
    public enum RequestHandled {
        public struct Measurements {
            /// From the request reaching the server to its response being
            /// built. A streamed body's transfer is not included.
            public var duration: Duration
        }
        public struct Metadata {
            /// `GET`, `POST`, …
            public var method: String
            /// The matched route's pattern — `/users/:id`, never the path
            /// itself, so the series count is the route count. A request a
            /// mount answered is its prefix and `*` (`/assets/*`); one
            /// nothing matched is `unmatched`, so a scanner walking random
            /// paths adds one series, not thousands.
            public var route: String
            public var status: Int
        }
    }
}

/// The HTTP server's metrics: their names, and their definitions over
/// ``HTTPEvents``.
public enum HTTPMetrics {
    /// ``HTTPEvents/RequestHandled``, counted by `method`, `route` and
    /// `status`.
    public static let requests = "alula_http_requests"
    /// ``HTTPEvents/RequestHandled``'s duration, by `method` and `route`.
    public static let duration = "alula_http_request_duration"

    /// What ``AlulaWebModule`` contributes to the reported metrics.
    public static let definitions: [TelemetryMetric] = [
        .counter(
            HTTPEvents.RequestHandled.self, name: "alula.http.requests",
            tags: \.method, \.route, \.status),
        .distribution(
            HTTPEvents.RequestHandled.self, \.duration, name: "alula.http.request.duration",
            unit: .milliseconds, tags: \.method, \.route),
    ]
}
