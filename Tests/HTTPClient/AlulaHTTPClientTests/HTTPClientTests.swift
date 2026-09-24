#if HTTPClient
import AlulaCore
import Foundation
import HTTPTypes
import InMemoryTracing
import Logging
import ServiceContextModule
import Synchronization
import Testing
import Tracing

@testable import AlulaHTTPClient
import AlulaHTTPClientTesting

private let url = URL(string: "https://api.example.com/v1/things?token=secret")!
private let fast = OutboundHTTPPolicy(
    maxAttempts: 3, backoffBase: .milliseconds(1), backoffCap: .milliseconds(5))

@Suite("Outbound HTTP client")
struct OutboundHTTPClientTests {

    @Test("a non-2xx is a response; decode demands success")
    func statusIsNotAnError() async throws {
        let client = OutboundHTTPClient(
            transport: StubHTTPTransport(responses: [.init(status: .notFound, body: Data("nope".utf8))]),
            policy: fast)
        let response = try await client.get(url)
        #expect(response.status == .notFound)
        #expect(throws: OutboundHTTPError.unexpectedStatus(404, bodyPrefix: "nope")) {
            try response.decode([String].self)
        }
    }

    @Test("an idempotent request retries a 503 and returns the success")
    func retriesIdempotent() async throws {
        let stub = StubHTTPTransport(responses: [
            .init(status: .serviceUnavailable), .init(status: .serviceUnavailable),
            .init(status: .ok, body: Data("[1]".utf8)),
        ])
        let client = OutboundHTTPClient(transport: stub, policy: fast)
        #expect(try await client.get(url).decode([Int].self) == [1])
        #expect(stub.requests.count == 3)
    }

    @Test("attempts run out: the last response is returned, not an error")
    func attemptsRunOut() async throws {
        let stub = StubHTTPTransport(responses: [.init(status: .badGateway)])
        let client = OutboundHTTPClient(transport: stub, policy: fast)
        #expect(try await client.get(url).status == .badGateway)
        #expect(stub.requests.count == 3)
    }

    @Test("a POST is never retried, unless it carries an Idempotency-Key")
    func postNeedsAKey() async throws {
        let plain = StubHTTPTransport(responses: [.init(status: .serviceUnavailable), .init(status: .ok)])
        _ = try await OutboundHTTPClient(transport: plain, policy: fast).post(url, json: ["a": 1])
        #expect(plain.requests.count == 1)

        let keyed = StubHTTPTransport(responses: [.init(status: .serviceUnavailable), .init(status: .ok)])
        var headers = HTTPFields()
        headers[HTTPField.Name("Idempotency-Key")!] = "order-42"
        let response = try await OutboundHTTPClient(transport: keyed, policy: fast)
            .post(url, json: ["a": 1], headers: headers)
        #expect(response.status == .ok)
        #expect(keyed.requests.count == 2)
    }

    @Test("connection failures retry; a 400 does not")
    func transportErrorsRetry() async throws {
        let calls = Mutex(0)
        let flaky = StubHTTPTransport { _ in
            if calls.withLock({ $0 += 1; return $0 }) < 3 {
                throw OutboundHTTPError.transport("connection reset")
            }
            return .init(status: .ok)
        }
        #expect(try await OutboundHTTPClient(transport: flaky, policy: fast).get(url).status == .ok)

        let bad = StubHTTPTransport(responses: [.init(status: .badRequest), .init(status: .ok)])
        #expect(try await OutboundHTTPClient(transport: bad, policy: fast).get(url).status == .badRequest)
        #expect(bad.requests.count == 1)
    }

    @Test("Retry-After is honoured up to the cap, and past it the answer is returned at once")
    func retryAfter() async throws {
        var busy = HTTPFields()
        busy[.retryAfter] = "1"
        let short = StubHTTPTransport(responses: [
            .init(status: .tooManyRequests, headers: busy), .init(status: .ok),
        ])
        let started = ContinuousClock.now
        #expect(try await OutboundHTTPClient(transport: short, policy: fast).get(url).status == .ok)
        #expect(ContinuousClock.now - started >= .seconds(1))

        var long = HTTPFields()
        long[.retryAfter] = "3600"
        let slow = StubHTTPTransport(responses: [.init(status: .tooManyRequests, headers: long)])
        let client = OutboundHTTPClient(transport: slow, policy: fast)
        let before = ContinuousClock.now
        #expect(try await client.get(url).status == .tooManyRequests)
        #expect(ContinuousClock.now - before < .seconds(1))
        #expect(slow.requests.count == 1)
    }

    @Test("an oversized response is refused")
    func sizeCap() async throws {
        let stub = StubHTTPTransport(responses: [.init(status: .ok, body: Data(count: 100))])
        var policy = fast
        policy.maxResponseBytes = 10
        await #expect(throws: OutboundHTTPError.responseTooLarge(limit: 10)) {
            _ = try await OutboundHTTPClient(transport: stub, policy: policy).get(url)
        }
    }

    @Test("a client span is recorded, its context injected, and the query string kept out of it")
    func tracing() async throws {
        let tracer = InMemoryTracer()
        let stub = StubHTTPTransport(responses: [.init(status: .ok)])
        _ = try await OutboundHTTPClient(transport: stub, policy: fast, tracer: tracer).get(url)

        let span = try #require(tracer.finishedSpans.first)
        #expect(span.kind == .client)
        #expect(span.operationName == "HTTP GET")
        #expect(span.attributes["url.full"]?.toSpanAttribute() == .string("https://api.example.com/v1/things"))
        #expect(span.attributes["http.response.status_code"]?.toSpanAttribute() == .int64(200))
        // What went out on the wire names this span, so the next service's
        // server span becomes its child.
        let sent = try #require(stub.requests.first)
        let injected = sent.headers[HTTPField.Name(InMemoryTracer.spanIDKey)!]
        #expect(injected == span.spanContext.spanID)
    }

    @Test("inside a request deadline, the attempt timeout shrinks to the time left")
    func deadlineClamps() async throws {
        final class Capturing: OutboundHTTPTransport {
            let seen = Mutex<[Duration]>([])
            func send(_ request: OutboundRequest, timeout: Duration, maxResponseBytes: Int)
                async throws -> OutboundResponse
            {
                seen.withLock { $0.append(timeout) }
                return OutboundResponse(status: .ok)
            }
        }
        let transport = Capturing()
        let client = OutboundHTTPClient(transport: transport, policy: fast)
        try await Deadline.$current.withValue(ContinuousClock.now.advanced(by: .seconds(2))) {
            _ = try await client.get(url)
        }
        let used = try #require(transport.seen.withLock { $0.first })
        #expect(used <= .seconds(2))
        #expect(used > .seconds(1))

        // Already past it: nothing is sent.
        await #expect(throws: OutboundHTTPError.self) {
            try await Deadline.$current.withValue(ContinuousClock.now.advanced(by: .seconds(-1))) {
                _ = try await client.get(url)
            }
        }
        #expect(transport.seen.withLock { $0.count } == 1)
    }

    @Test("configuration is read and non-positive values refused")
    func configuration() throws {
        let policy = try OutboundHTTPPolicy(
            configuration: Configuration(values: ["http-client.timeout-seconds": "5", "http-client.max-attempts": "1"]))
        #expect(policy.timeout == .seconds(5))
        #expect(policy.maxAttempts == 1)
        #expect(throws: OutboundHTTPConfigurationError.self) {
            try OutboundHTTPPolicy(configuration: Configuration(values: ["http-client.max-attempts": "0"]))
        }
    }
}
#endif
