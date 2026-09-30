import AsyncHTTPClient
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1

/// One HTTP/2 POST to the gateway, with no Apple semantics in it. Built by
/// ``APNSClient``; a transport sends it and reports what came back.
public struct APNSRequest: Sendable, Equatable {
    /// The gateway's `/3/device/<token>` URL.
    public let url: URL
    /// In order, as sent. Names are lowercase, as HTTP/2 requires.
    public let headers: [(name: String, value: String)]
    /// The JSON payload.
    public let body: Data
    /// The limit on this request, connection included.
    public let timeout: Duration

    /// A request as ``APNSClient`` builds it.
    public init(url: URL, headers: [(name: String, value: String)], body: Data, timeout: Duration) {
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    /// The first value for `name`, case-insensitively.
    public func header(_ name: String) -> String? {
        headers.first { $0.name.lowercased() == name.lowercased() }?.value
    }

    /// Same URL, body, timeout, and headers in the same order.
    public static func == (lhs: APNSRequest, rhs: APNSRequest) -> Bool {
        lhs.url == rhs.url && lhs.body == rhs.body && lhs.timeout == rhs.timeout
            && lhs.headers.map { "\($0.name)=\($0.value)" }
                == rhs.headers.map { "\($0.name)=\($0.value)" }
    }
}

/// What the gateway answered, before ``APNSClient`` reads meaning into it.
public struct APNSRawResponse: Sendable, Equatable {
    /// The HTTP status; `200` is accepted.
    public let status: Int
    /// Lowercased names.
    public let headers: [String: String]
    /// The body: empty on `200`, JSON with `reason` on a refusal.
    public let body: Data

    /// A response; header names are lowercased here.
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(
            uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }
}

/// The seam between the client and the network — public so
/// `AlulaAPNSTesting` can stand a recorder in for the gateway, the way
/// `JWKSSource` lets the security suite run without an identity provider.
public protocol APNSTransport: Sendable {
    /// Sends `request` and returns whatever status the gateway answered.
    /// Throws only when no answer came (connection, TLS, timeout); the
    /// client reports that as ``APNSError/Reason/transportFailure``.
    func post(_ request: APNSRequest) async throws -> APNSRawResponse
}

/// The production transport: AsyncHTTPClient's shared client, which
/// negotiates HTTP/2 over TLS by ALPN — the only protocol the gateway
/// speaks — and pools the connection between pushes.
///
/// `HTTPClient.shared` rather than a client of this module's own, for the
/// reason the JWKS fetch uses it: a process-wide client that needs no
/// lifecycle of its own. A dedicated client with tuned idle timeouts would
/// give `AlulaAPNSModule` a `service`; nothing has needed it yet.
public struct AsyncHTTPAPNSTransport: APNSTransport {
    /// Error bodies are a few hundred bytes; anything past this is not the
    /// gateway.
    static let maxResponseBytes = 65_536

    /// The transport over `HTTPClient.shared`.
    public init() {}

    /// POSTs over HTTP/2, honouring `request.timeout`, and reads at most
    /// 64 KiB of body.
    public func post(_ request: APNSRequest) async throws -> APNSRawResponse {
        var clientRequest = HTTPClientRequest(url: request.url.absoluteString)
        clientRequest.method = .POST
        for (name, value) in request.headers {
            clientRequest.headers.add(name: name, value: value)
        }
        clientRequest.body = .bytes(ByteBuffer(data: request.body))
        let response = try await HTTPClient.shared.execute(
            clientRequest, timeout: TimeAmount(request.timeout))
        let body = try await response.body.collect(upTo: Self.maxResponseBytes)
        var headers: [String: String] = [:]
        for (name, value) in response.headers {
            headers[name.lowercased()] = value
        }
        return APNSRawResponse(
            status: Int(response.status.code), headers: headers, body: Data(buffer: body))
    }
}
