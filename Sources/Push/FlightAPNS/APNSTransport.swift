import AsyncHTTPClient
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1

/// One HTTP/2 POST to the gateway, with no Apple semantics in it. Built by
/// ``APNSClient``; a transport sends it and reports what came back.
public struct APNSRequest: Sendable, Equatable {
    public let url: URL
    /// In order, as sent. Names are lowercase, as HTTP/2 requires.
    public let headers: [(name: String, value: String)]
    public let body: Data
    public let timeout: Duration

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

    public static func == (lhs: APNSRequest, rhs: APNSRequest) -> Bool {
        lhs.url == rhs.url && lhs.body == rhs.body && lhs.timeout == rhs.timeout
            && lhs.headers.map { "\($0.name)=\($0.value)" }
                == rhs.headers.map { "\($0.name)=\($0.value)" }
    }
}

/// What the gateway answered, before ``APNSClient`` reads meaning into it.
public struct APNSRawResponse: Sendable, Equatable {
    public let status: Int
    /// Lowercased names.
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(
            uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }
}

/// The seam between the client and the network — public so
/// `FlightAPNSTesting` can stand a recorder in for the gateway, the way
/// `JWKSSource` lets the security suite run without an identity provider.
public protocol APNSTransport: Sendable {
    func post(_ request: APNSRequest) async throws -> APNSRawResponse
}

/// The production transport: AsyncHTTPClient's shared client, which
/// negotiates HTTP/2 over TLS by ALPN — the only protocol the gateway
/// speaks — and pools the connection between pushes.
///
/// `HTTPClient.shared` rather than a client of this module's own, for the
/// reason the JWKS fetch uses it: a process-wide client that needs no
/// lifecycle of its own. A dedicated client with tuned idle timeouts would
/// give `FlightAPNSModule` a `service`; nothing has needed it yet.
public struct AsyncHTTPAPNSTransport: APNSTransport {
    /// Error bodies are a few hundred bytes; anything past this is not the
    /// gateway.
    static let maxResponseBytes = 65_536

    public init() {}

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
