import AlulaCore
import Foundation
import HTTPTypes
import Instrumentation
import Logging
import ServiceContextModule
import Tracing

/// A request to another service.
public struct OutboundRequest: Sendable {
    public var method: HTTPRequest.Method
    public var url: URL
    public var headers: HTTPFields
    public var body: Data?
    /// Overrides the client's timeout for this request: the whole of one
    /// attempt, from connecting to the last byte of the response.
    public var timeout: Duration?
    /// Whether repeating this request is safe. Nil infers it: `GET`, `HEAD`,
    /// `OPTIONS`, `PUT` and `DELETE` are, and so is any request carrying an
    /// `Idempotency-Key` header. A `POST` without one is never retried.
    public var idempotent: Bool?

    public init(
        method: HTTPRequest.Method = .get, url: URL, headers: HTTPFields = HTTPFields(),
        body: Data? = nil, timeout: Duration? = nil, idempotent: Bool? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.idempotent = idempotent
    }

    var isIdempotent: Bool {
        if let idempotent { return idempotent }
        if headers[HTTPField.Name("Idempotency-Key")!] != nil { return true }
        return [.get, .head, .options, .put, .delete].contains(method)
    }
}

/// What came back.
public struct OutboundResponse: Sendable {
    public var status: HTTPResponse.Status
    public var headers: HTTPFields
    public var body: Data

    public init(status: HTTPResponse.Status, headers: HTTPFields = HTTPFields(), body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// The body as JSON, after checking the status is 2xx.
    public func decode<T: Decodable>(_ type: T.Type, using decoder: JSONDecoder = JSONDecoder())
        throws -> T
    {
        guard status.kind == .successful else {
            throw OutboundHTTPError.unexpectedStatus(status.code, bodyPrefix: bodyPrefix)
        }
        return try decoder.decode(type, from: body)
    }

    var bodyPrefix: String {
        String(decoding: body.prefix(200), as: UTF8.self)
    }
}

public enum OutboundHTTPError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A non-2xx status where one was required.
    case unexpectedStatus(Int, bodyPrefix: String)
    /// The response body exceeded the client's `maxResponseBytes`.
    case responseTooLarge(limit: Int)
    /// No response within the timeout.
    case timedOut(Duration)
    /// Could not connect, or the connection broke.
    case transport(String)

    public var description: String {
        switch self {
        case .unexpectedStatus(let code, let body): "unexpected HTTP \(code): \(body)"
        case .responseTooLarge(let limit): "response larger than \(limit) bytes"
        case .timedOut(let timeout): "no response within \(timeout)"
        case .transport(let reason): "HTTP transport failed: \(reason)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .timedOut, .transport: true
        case .unexpectedStatus, .responseTooLarge: false
        }
    }
}

/// Sends one attempt of one request. The client adds retries, tracing and
/// logging around it; tests replace it with `StubHTTPTransport`.
public protocol OutboundHTTPTransport: Sendable {
    func send(_ request: OutboundRequest, timeout: Duration, maxResponseBytes: Int) async throws
        -> OutboundResponse
}

/// How the client behaves. `http-client.*` in configuration.
public struct OutboundHTTPPolicy: Sendable, Equatable {
    /// Per attempt.
    public var timeout: Duration
    /// Attempts for a retryable failure, the first included.
    public var maxAttempts: Int
    public var backoffBase: Duration
    public var backoffCap: Duration
    /// A `Retry-After` longer than this is not waited for; the error is
    /// returned instead.
    public var maxRetryAfter: Duration
    public var maxResponseBytes: Int
    /// Statuses that mean "try again", for idempotent requests.
    public var retryStatuses: Set<Int>

    public init(
        timeout: Duration = .seconds(30), maxAttempts: Int = 3,
        backoffBase: Duration = .milliseconds(200), backoffCap: Duration = .seconds(5),
        maxRetryAfter: Duration = .seconds(10), maxResponseBytes: Int = 10 << 20,
        retryStatuses: Set<Int> = [429, 502, 503, 504]
    ) {
        self.timeout = timeout
        self.maxAttempts = max(1, maxAttempts)
        self.backoffBase = backoffBase
        self.backoffCap = backoffCap
        self.maxRetryAfter = maxRetryAfter
        self.maxResponseBytes = maxResponseBytes
        self.retryStatuses = retryStatuses
    }

    public init(configuration: Configuration) throws {
        func positive(_ key: String, _ fallback: Int) throws -> Int {
            let value = try configuration.getIfPresent(key, as: Int.self) ?? fallback
            guard value > 0 else {
                throw OutboundHTTPConfigurationError(description: "\(key) must be positive")
            }
            return value
        }
        self.init(
            timeout: .seconds(try positive("http-client.timeout-seconds", 30)),
            maxAttempts: try positive("http-client.max-attempts", 3),
            maxResponseBytes: try positive("http-client.max-response-bytes", 10 << 20))
    }

    func backoff(after attempt: Int) -> Duration {
        let base = backoffBase * (1 << min(attempt - 1, 20))
        let capped = min(base, backoffCap)
        return capped * Double.random(in: 0.5...1.0)
    }
}

public struct OutboundHTTPConfigurationError: Error, Sendable, CustomStringConvertible {
    public let description: String
}

/// Calls other services: timeouts on every attempt, retries where repeating
/// is safe, a client span per request with trace context propagated, and a
/// cap on how much of a response is read.
///
/// ```swift
/// @Service struct Weather {
///     @Inject var http: OutboundHTTPClient
///
///     func forecast(for city: String) async throws -> Forecast {
///         try await http.get(URL(string: "https://api.example.com/forecast?city=\(city)")!)
///             .decode(Forecast.self)
///     }
/// }
/// ```
///
/// **Retries** happen only for idempotent requests (see
/// `OutboundRequest.idempotent`): on a connection failure, a timeout, or a
/// 429/502/503/504, up to `maxAttempts`, with jittered exponential backoff.
/// A `Retry-After` header is honoured up to `maxRetryAfter`. Past that the
/// response is returned as it is, because waiting a minute inside a request
/// helps nobody.
///
/// **Deadlines.** Inside a request with a timeout (`Deadline.current`),
/// each attempt's timeout shrinks to the time left, and no retry waits past
/// it.
///
/// **Trace context** is whatever span is current (the server span, inside
/// a request), injected into the outgoing headers by the application's
/// instrument, so W3C `traceparent` reaches the next service.
public struct OutboundHTTPClient: Sendable {
    public let transport: any OutboundHTTPTransport
    public let policy: OutboundHTTPPolicy
    let logger: Logger
    let tracer: (any Tracer)?

    /// - Parameters:
    ///   - transport: What sends each attempt: `AsyncHTTPTransport`, or a
    ///     stub in tests.
    ///   - policy: Timeouts, retries and the response size cap.
    ///   - tracer: Nil uses the one the application bootstrapped
    ///     (`InstrumentationSystem.tracer`), read per request.
    ///   - logger: Where retries are noted, at debug level.
    public init(
        transport: any OutboundHTTPTransport, policy: OutboundHTTPPolicy = OutboundHTTPPolicy(),
        tracer: (any Tracer)? = nil, logger: Logger = Logger(label: "alula.http-client")
    ) {
        self.transport = transport
        self.policy = policy
        self.tracer = tracer
        self.logger = logger
    }

    /// Sends `request`, retrying as the policy allows. A non-2xx status is a
    /// response, not an error. Use `decode` to demand success.
    public func send(_ request: OutboundRequest) async throws -> OutboundResponse {
        let host = request.url.host ?? "unknown"
        let tracer = self.tracer ?? InstrumentationSystem.tracer
        let span = tracer.startAnySpan(
            "HTTP \(request.method.rawValue)", context: ServiceContext.current ?? .topLevel,
            ofKind: .client)
        defer { span.end() }
        span.attributes["http.request.method"] = request.method.rawValue
        span.attributes["server.address"] = host
        span.attributes["url.full"] = redacted(request.url)

        var request = request
        tracer.inject(span.context, into: &request.headers, using: HTTPFieldsInjector())

        let configured = request.timeout ?? policy.timeout
        var attempt = 0
        while true {
            attempt += 1
            // Inside a request with a deadline, never wait past it: the
            // caller's client has already been answered by then.
            let timeout = min(configured, Deadline.remaining ?? configured)
            guard timeout > .zero else {
                span.setStatus(SpanStatus(code: .error))
                throw OutboundHTTPError.timedOut(.zero)
            }
            do {
                let response = try await transport.send(
                    request, timeout: timeout, maxResponseBytes: policy.maxResponseBytes)
                if request.isIdempotent, attempt < policy.maxAttempts,
                    policy.retryStatuses.contains(response.status.code),
                    let wait = retryDelay(response, attempt: attempt),
                    wait < (Deadline.remaining ?? .seconds(Int64.max))
                {
                    logger.debug(
                        "retrying",
                        metadata: ["status": "\(response.status.code)", "host": "\(host)"])
                    try await Task.sleep(for: wait)
                    continue
                }
                span.attributes["http.response.status_code"] = response.status.code
                if response.status.kind == .serverError { span.setStatus(SpanStatus(code: .error)) }
                return response
            } catch let error as OutboundHTTPError
                where error.isRetryable && request.isIdempotent && attempt < policy.maxAttempts
            {
                // The same rule as a retried status: the wait must end
                // before the deadline does, or there is no retry. Checking
                // only that some time remained let a 180 ms backoff start
                // with 40 ms left.
                let wait = policy.backoff(after: attempt)
                guard wait < (Deadline.remaining ?? .seconds(Int64.max)) else {
                    span.recordError(error)
                    span.setStatus(SpanStatus(code: .error))
                    throw error
                }
                logger.debug("retrying", metadata: ["error": "\(error)", "host": "\(host)"])
                try await Task.sleep(for: wait)
            } catch {
                span.recordError(error)
                span.setStatus(SpanStatus(code: .error))
                throw error
            }
        }
    }

    public func get(_ url: URL, headers: HTTPFields = HTTPFields()) async throws -> OutboundResponse {
        try await send(OutboundRequest(method: .get, url: url, headers: headers))
    }

    /// POSTs `body` as JSON. Not retried unless `headers` carries an
    /// `Idempotency-Key`.
    public func post<Body: Encodable>(
        _ url: URL, json body: Body, headers: HTTPFields = HTTPFields(),
        encoder: JSONEncoder = JSONEncoder()
    ) async throws -> OutboundResponse {
        var headers = headers
        headers[.contentType] = "application/json"
        return try await send(
            OutboundRequest(method: .post, url: url, headers: headers, body: try encoder.encode(body)))
    }

    private func retryDelay(_ response: OutboundResponse, attempt: Int) -> Duration? {
        guard let raw = response.headers[.retryAfter],
            let wait = RetryAfter.parse(raw, now: Date())
        else { return policy.backoff(after: attempt) }
        return wait <= policy.maxRetryAfter ? wait : nil
    }

    /// The URL without its query string or credentials, for span attributes:
    /// query strings carry tokens often enough that recording them is a leak.
    private func redacted(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "unparseable"
        }
        components.query = nil
        components.user = nil
        components.password = nil
        return components.string ?? "unparseable"
    }
}

struct HTTPFieldsInjector: Injector {
    func inject(_ value: String, forKey key: String, into carrier: inout HTTPFields) {
        guard let name = HTTPField.Name(key) else { return }
        carrier[name] = value
    }
}

/// `Retry-After` in both of RFC 9110's forms (§10.2.3): delay-seconds, or an
/// HTTP-date. A date in the past means now. Nil when it is neither, and the
/// caller falls back to its own backoff.
enum RetryAfter {
    static func parse(_ raw: String, now: Date) -> Duration? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if let seconds = Int(value) {
            return seconds >= 0 ? .seconds(seconds) : nil
        }
        guard let date = httpDate(value) else { return nil }
        let delta = date.timeIntervalSince(now)
        return delta <= 0 ? .zero : .milliseconds(Int64((delta * 1000).rounded(.up)))
    }

    /// IMF-fixdate, and the two obsolete forms a recipient must still accept
    /// (RFC 9110 §5.6.7): RFC 850 and asctime.
    static func httpDate(_ value: String) -> Date? {
        // Built per call: this runs only on a retried response, and a shared
        // formatter would need a lock to be safe across tasks.
        for pattern in patterns {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = pattern
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static let patterns = [
        "EEE, dd MMM yyyy HH:mm:ss 'GMT'",
        "EEEE, dd-MMM-yy HH:mm:ss 'GMT'",
        "EEE MMM d HH:mm:ss yyyy",
    ]
}

extension OutboundHTTPConfigurationError: ModuleConfigurationError {}
