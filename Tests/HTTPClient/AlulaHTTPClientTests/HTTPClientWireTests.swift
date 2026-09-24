#if HTTPClient && Web
import AlulaCore
import AlulaTransport
import AlulaWeb
import Foundation
import HTTPTypes
import InMemoryTracing
import Synchronization
import Testing

@testable import AlulaHTTPClient

/// The real transport against a real Alula server on a loopback port.
@Suite("Outbound HTTP client on the wire", .serialized)
struct HTTPClientWireTests {
    final class Hits: Sendable {
        let count = Mutex(0)
        let lastHeaders = Mutex(HTTPFields())
    }

    private func withServer(
        _ routes: [RouteRegistration], _ body: @Sendable (URL) async throws -> Void
    ) async throws {
        let dispatch = try DispatchBuilder.build(routes: routes, middleware: [])
        let (ports, bound) = AsyncStream<Int>.makeStream()
        let transport = AlulaTransport(
            configuration: AlulaTransportConfiguration(port: 0, onBound: { bound.yield($0) }),
            dispatch: dispatch)
        let server = Task { try await transport.run() }
        defer { server.cancel() }
        var iterator = ports.makeAsyncIterator()
        let port = try #require(await iterator.next())
        try await body(URL(string: "http://127.0.0.1:\(port)")!)
        server.cancel()
        _ = try? await server.value
    }

    private let policy = OutboundHTTPPolicy(
        timeout: .seconds(5), maxAttempts: 3, backoffBase: .milliseconds(10),
        backoffCap: .milliseconds(50))

    @Test("JSON round trip, and trace headers arrive at the server")
    func roundTrip() async throws {
        let hits = Hits()
        try await withServer([
            RouteRegistration(method: .get, path: "/things") { context in
                hits.lastHeaders.withLock { $0 = context.request.headers }
                return .data(Data("[1,2,3]".utf8), contentType: .json)
            }
        ]) { base in
            let tracer = InMemoryTracer()
            let client = OutboundHTTPClient(transport: AsyncHTTPTransport(), policy: policy, tracer: tracer)
            #expect(try await client.get(base.appending(path: "things")).decode([Int].self) == [1, 2, 3])
            let span = try #require(tracer.finishedSpans.first)
            let received = hits.lastHeaders.withLock { $0 }
            #expect(received[HTTPField.Name(InMemoryTracer.spanIDKey)!] == span.spanContext.spanID)
        }
    }

    @Test("a 503 over a real socket is retried until it succeeds")
    func retriesOverTheWire() async throws {
        let hits = Hits()
        try await withServer([
            RouteRegistration(method: .get, path: "/flaky") { _ in
                let n = hits.count.withLock { $0 += 1; return $0 }
                return n < 3 ? .text("busy", status: .serviceUnavailable) : .text("ok")
            }
        ]) { base in
            let client = OutboundHTTPClient(transport: AsyncHTTPTransport(), policy: policy)
            let response = try await client.get(base.appending(path: "flaky"))
            #expect(response.status == .ok)
            #expect(hits.count.withLock { $0 } == 3)
        }
    }

    @Test("an oversized body is cut off, a slow one times out, a dead port is a transport error")
    func failures() async throws {
        try await withServer([
            RouteRegistration(method: .get, path: "/big") { _ in
                .data(Data(count: 64 * 1024), contentType: .json)
            },
            RouteRegistration(method: .get, path: "/slow") { _ in
                try await Task.sleep(for: .seconds(1))
                return .text("late")
            },
        ]) { base in
            var capped = policy
            capped.maxResponseBytes = 1024
            await #expect(throws: OutboundHTTPError.responseTooLarge(limit: 1024)) {
                _ = try await OutboundHTTPClient(transport: AsyncHTTPTransport(), policy: capped)
                    .get(base.appending(path: "big"))
            }

            var quick = policy
            quick.timeout = .milliseconds(200)
            quick.maxAttempts = 1
            await #expect(throws: OutboundHTTPError.timedOut(.milliseconds(200))) {
                _ = try await OutboundHTTPClient(transport: AsyncHTTPTransport(), policy: quick)
                    .get(base.appending(path: "slow"))
            }
        }
        var once = policy
        once.maxAttempts = 1
        do {
            _ = try await OutboundHTTPClient(transport: AsyncHTTPTransport(), policy: once)
                .get(URL(string: "http://127.0.0.1:1/nothing")!)
            Issue.record("connected to port 1")
        } catch OutboundHTTPError.transport {
        }
    }
}
#endif
