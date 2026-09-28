import AlulaCore
import AlulaSupportFoundation
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
    /// Overrides the client's timeout for this request: one attempt, from
    /// connecting until the response head arrives. See
    /// ``OutboundHTTPPolicy/timeout`` for what it does not cover.
    public var timeout: Duration?
    /// Whether repeating this request is safe. Nil infers it: `GET`, `HEAD`,
    /// `OPTIONS`, `PUT` and `DELETE` are, and so is any request carrying an
    /// `Idempotency-Key` header. A `POST` without one is never retried.
    ///
    /// `true` opts any method into retries; set it only when the receiver
    /// deduplicates, since a retried attempt may follow one the server
    /// already acted on. The client does not generate an `Idempotency-Key`;
    /// one you set is sent unchanged on every attempt.
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

/// Why an outbound call failed. ``OutboundHTTPError/timedOut(_:)`` and
/// ``OutboundHTTPError/transport(_:)`` are the retryable ones, for
/// idempotent requests; ``OutboundHTTPClient/send(_:)`` throws the error of
/// the attempt it stopped at.
public enum OutboundHTTPError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A non-2xx status where one was required. Thrown only by
    /// ``OutboundResponse/decode(_:using:)``, never by `send`. The body
    /// prefix is its first 200 bytes.
    case unexpectedStatus(Int, bodyPrefix: String)
    /// The response body exceeded the client's `maxResponseBytes`. Not
    /// retried.
    case responseTooLarge(limit: Int)
    /// No response within the attempt's timeout. Also thrown, with `.zero`
    /// and nothing sent, when the enclosing request's deadline has already
    /// passed. For a request that is not retried, the server may still
    /// have acted on it.
    case timedOut(Duration)
    /// Could not connect, or the connection broke. When it broke after the
    /// request was written, the server may have acted on it; that is why a
    /// non-idempotent request is not retried.
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
///
/// A conformance must not retry itself. It should enforce `timeout` on the
/// attempt and throw ``OutboundHTTPError/timedOut(_:)`` or
/// ``OutboundHTTPError/transport(_:)`` for failures worth retrying, and
/// ``OutboundHTTPError/responseTooLarge(limit:)`` past `maxResponseBytes`.
/// Any other error, `CancellationError` included, ends the call unretried.
/// A non-2xx status is returned, not thrown.
public protocol OutboundHTTPTransport: Sendable {
    func send(_ request: OutboundRequest, timeout: Duration, maxResponseBytes: Int) async throws
        -> OutboundResponse
}

/// How the client behaves. `http-client.*` in configuration.
public struct OutboundHTTPPolicy: Sendable, Equatable {
    /// Per attempt, from connecting until the response head arrives
    /// (redirects included). With `AsyncHTTPTransport`, reading the body
    /// is not under it: a body that keeps trickling in is bounded only by
    /// ``OutboundHTTPPolicy/maxResponseBytes`` and AsyncHTTPClient's idle
    /// read timeout. There is no budget across attempts either: a call can
    /// take `maxAttempts` timeouts plus the backoffs between them, unless a
    /// request deadline cuts it short.
    public var timeout: Duration
    /// Attempts for a retryable failure, the first included. Values below 1
    /// are raised to 1.
    public var maxAttempts: Int
    /// The wait after the first failed attempt; it doubles per attempt, up to
    /// ``OutboundHTTPPolicy/backoffCap``, and each wait is jittered down to between half and all
    /// of that.
    public var backoffBase: Duration
    /// The longest backoff between attempts, before jitter.
    public var backoffCap: Duration
    /// A `Retry-After` longer than this is not waited for; the response is
    /// returned as it is, without another attempt.
    public var maxRetryAfter: Duration
    /// The most response body read, in bytes; past it the call throws
    /// ``OutboundHTTPError/responseTooLarge(limit:)``.
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

    /// Reads `http-client.timeout-seconds`, `http-client.max-attempts` and
    /// `http-client.max-response-bytes`; the rest keep their defaults.
    /// Throws ``OutboundHTTPConfigurationError`` for a value that is not
    /// positive.
    public init(configuration: Configuration) throws {
        func positive(_ key: String, _ fallback: Int) throws -> Int {
            try configuration.positive(
                key, orThrow: { OutboundHTTPConfigurationError(description: $0.description) })
                ?? fallback
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

/// An `http-client.*` value that cannot be used, reported at startup.
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
    ///
    /// When the attempts run out on a retryable status, the last response
    /// is returned; on a timeout or connection failure, the last
    /// ``OutboundHTTPError`` is thrown. A task cancelled during a backoff
    /// wait ends with `CancellationError` instead of another attempt.
    /// Every attempt carries the same headers, trace context included.
    public func send(_ request: OutboundRequest) async throws -> OutboundResponse {
        let host = request.url.host ?? "unknown"
        let tracer = self.tracer ?? InstrumentationSystem.tracer
        let span = tracer.startAnySpan(
            "HTTP \(request.method.rawValue)", context: ServiceContext.current ?? .topLevel,
            ofKind: .client)
        defer { span.end() }
        span.attributes["http.request.method"] = request.method.rawValue
        span.attributes["server.address"] = host
        span.attributes["url.full"] = request.url.redactedForLog

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

    /// GETs `url`. Retried as the policy allows.
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
        guard let date = HTTPDateCodec.parse(value) else { return nil }
        let delta = date.timeIntervalSince(now)
        return delta <= 0 ? .zero : .milliseconds(Int64((delta * 1000).rounded(.up)))
    }
}

extension OutboundHTTPConfigurationError: ModuleConfigurationError {}
