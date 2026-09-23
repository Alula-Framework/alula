/// A host and, when known, a port — the shape both a raw TCP peer and a
/// forwarded-for entry take. Deliberately not a stronger type: an
/// `X-Forwarded-For` entry never carries a port, so `port` is optional even
/// though ``Request/remoteAddress`` always has one.
///
/// `host` is the string form of the address (`"203.0.113.7"`,
/// `"2001:db8::1"`), never a hostname — nothing here does DNS. Comparing two
/// addresses, or testing one against a configured range, is
/// `IPAddress`'s job; this type is the one a handler actually wants to
/// read, log, or put in a rate limit key.
public struct PeerAddress: Sendable, Equatable, Hashable, CustomStringConvertible {
    public let host: String
    public let port: Int?

    public init(host: String, port: Int? = nil) {
        self.host = host
        self.port = port
    }

    public var description: String {
        guard let port else { return host }
        // Bracketed when the host itself contains a colon — an IPv6
        // literal — so `host:port` stays unambiguous. `2001:db8::1:8080`
        // parses as a different address entirely without the brackets.
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

/// `Request`'s storage for ``PeerAddress``, boxed to keep the struct copy
/// cheap. See the doc comment on `Request.remoteAddress`.
final class RemoteAddressBox: Sendable {
    let value: PeerAddress
    init(_ value: PeerAddress) { self.value = value }
}
