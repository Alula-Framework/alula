import AlulaHTTPClient
import Foundation
import HTTPTypes
import Synchronization

/// An `OutboundHTTPTransport` that answers from a closure and records every
/// request, so code calling other services is tested without a network.
///
/// ```swift
/// let stub = StubHTTPTransport { request in
///     request.url.path == "/forecast"
///         ? .init(status: .ok, body: Data(#"{"high":21}"#.utf8))
///         : .init(status: .notFound)
/// }
/// let weather = Weather(http: OutboundHTTPClient(transport: stub))
/// #expect(try await weather.forecast(for: "Oslo").high == 21)
/// #expect(stub.requests.count == 1)
/// ```
public final class StubHTTPTransport: OutboundHTTPTransport {
    public typealias Responder = @Sendable (OutboundRequest) async throws -> OutboundResponse

    private let responder: Responder
    private let recorded = Mutex<[OutboundRequest]>([])

    public init(_ responder: @escaping Responder) {
        self.responder = responder
    }

    /// Answers with these, in order; the last one repeats.
    public convenience init(responses: [OutboundResponse]) {
        precondition(!responses.isEmpty, "give at least one response")
        let queue = Mutex(responses)
        self.init { _ in
            queue.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
        }
    }

    /// Every request sent, in order: each attempt of a retried one included.
    public var requests: [OutboundRequest] { recorded.withLock { $0 } }

    public func send(_ request: OutboundRequest, timeout: Duration, maxResponseBytes: Int)
        async throws -> OutboundResponse
    {
        recorded.withLock { $0.append(request) }
        let response = try await responder(request)
        guard response.body.count <= maxResponseBytes else {
            throw OutboundHTTPError.responseTooLarge(limit: maxResponseBytes)
        }
        return response
    }
}
