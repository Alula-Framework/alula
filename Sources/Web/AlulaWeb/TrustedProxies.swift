import AlulaCore
import HTTPTypes

/// Whether — and how far back — to trust `X-Forwarded-For`.
///
/// ``RequestContext/clientAddress`` is `request.remoteAddress` by default,
/// unconditionally: that is the actual TCP peer, reported by the kernel,
/// and nothing a client sends can change it. Behind a reverse proxy the
/// TCP peer is the proxy, not the caller, and the real address lives in a
/// header the proxy sets — which is exactly why trusting it needs a
/// policy. Anyone able to open a connection to this process can set
/// `X-Forwarded-For` to any value they like; the only reason to believe
/// one is that it came from a hop named here.
///
/// **The default trusts nothing.** There is no permissive spelling — no
/// "trust anyone," the way ``AllowedOrigins/any`` at least has a
/// legitimate narrow use guarded at construction. Trusting an unconfigured
/// `X-Forwarded-For` has no legitimate use: it lets any caller claim to be
/// any address. `Cookie`'s `httpOnly`/`sameSite` defaults and `Sessions`'
/// `cookie-secure` default follow the identical rule — the permissive
/// behaviour exists only where an operator explicitly asks for it.
///
/// ```swift
/// let proxies = try TrustedProxies(cidrs: ["10.0.0.0/8"])   // your load balancer's subnet
/// ```
public struct TrustedProxies: Sendable, Equatable {
    private let ranges: [CIDRBlock]

    /// No proxies trusted. `clientAddress` is always the raw peer, and
    /// `X-Forwarded-For` is never read. What an application with no
    /// reverse proxy in front of it wants, and the default.
    public static let none = TrustedProxies(ranges: [])

    private init(ranges: [CIDRBlock]) {
        self.ranges = ranges
    }

    /// - Parameter cidrs: Every hop between a caller and this process that
    ///   is allowed to set `X-Forwarded-For` — your load balancer's
    ///   subnet, your CDN's published edge ranges — as CIDR blocks
    ///   (`"10.0.0.0/8"`) or single addresses (`"203.0.113.5/32"`). Not
    ///   the internet at large, and not your own service's address: this
    ///   names the infrastructure in front of you, never the callers
    ///   behind it.
    /// - Throws: ``TrustedProxiesError`` naming the first entry that does
    ///   not parse.
    public init(cidrs: [String]) throws {
        self.ranges = try cidrs.map {
            guard let block = CIDRBlock($0) else {
                throw TrustedProxiesError.invalidRange($0)
            }
            return block
        }
    }

    /// Reads `web.trusted-proxies`: comma-separated CIDR blocks, the same
    /// convention `security.oidc.roles-claim` uses for a list-shaped
    /// value. Absent means ``none``.
    public init(configuration: Configuration) throws {
        guard let raw: String = try configuration.getIfPresent(TrustedProxiesConfigKey.ranges)
        else {
            self = .none
            return
        }
        let entries = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        try self.init(cidrs: entries)
    }

    func isTrusted(_ address: PeerAddress) -> Bool {
        guard let parsed = IPAddress(address.host) else { return false }
        return ranges.contains { $0.contains(parsed) }
    }

    var isConfigured: Bool { !ranges.isEmpty }

    /// The real client address for `request`, or `nil` when it cannot be
    /// determined.
    ///
    /// With nothing configured this is always `request.remoteAddress` —
    /// the socket peer — and `X-Forwarded-For` is never inspected, so a
    /// caller cannot spoof it by simply setting the header.
    ///
    /// With a configured range: `X-Forwarded-For` is a comma-separated
    /// list, each hop appending what it saw to the end before forwarding,
    /// so the rightmost entry is what the hop closest to this process
    /// reported. Walk it from the right. As long as an entry is itself a
    /// trusted proxy, keep walking — that hop is vouched for, so what it
    /// reported deserves a look too. The **first entry that is not a
    /// trusted proxy** is the client, and the walk stops there: everything
    /// further left is exactly the part of the header an untrusted party
    /// could have written by hand, so using it would mean trusting the
    /// caller's own unverified claim about itself.
    func clientAddress(for request: Request) -> PeerAddress? {
        guard let remoteAddress = request.remoteAddress else { return nil }
        guard isConfigured, isTrusted(remoteAddress) else { return remoteAddress }

        guard let header = request.headers[.xForwardedFor] else {
            // A trusted proxy that sent no header at all — misconfigured
            // on its side, or a direct connection from inside the trusted
            // range with nothing further back. Its own address is the
            // most honest answer there is.
            return remoteAddress
        }
        let entries = header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !entries.isEmpty else { return remoteAddress }

        for entry in entries.reversed() {
            // Not parseable at all: stop rather than guess. Every entry to
            // the right of this one was already confirmed to be one of
            // *our* proxies, which means none of them was the client —
            // the client is presumably this entry, and it is garbage.
            guard let parsedEntry = IPAddress(entry) else { return nil }
            let candidate = PeerAddress(host: entry)
            guard ranges.contains(where: { $0.contains(parsedEntry) }) else {
                return candidate
            }
        }
        // Every entry in the header claimed to be one of our own trusted
        // proxies. There is no untrusted boundary in it anywhere, so there
        // is no address in it that is safe to call "the client."
        return nil
    }
}

/// A `web.trusted-proxies` entry that is not a CIDR block. Thrown at
/// composition.
public struct TrustedProxiesError: Error, Sendable, Equatable, CustomStringConvertible {
    public let range: String

    public static func invalidRange(_ range: String) -> TrustedProxiesError {
        TrustedProxiesError(range: range)
    }

    public var description: String {
        """
        \(TrustedProxiesConfigKey.ranges) contains "\(range)", which is not \
        <address>/<prefix-length> — an IPv4 or IPv6 address, a slash, and a prefix length \
        in range for that address's family (0-32 for IPv4, 0-128 for IPv6). A single \
        address is its narrowest block: "203.0.113.5/32".
        """
    }
}

public enum TrustedProxiesConfigKey {
    public static let root = "web.trusted-proxies"
    /// `web.trusted-proxies` — comma-separated CIDR blocks.
    public static let ranges = "web.trusted-proxies"
}

extension HTTPField.Name {
    /// Force-unwrapped: both are literals, and `HeaderNameTests` pins that
    /// the strings are valid field names so the unwrap cannot fail silently
    /// on a typo nobody ran.
    static let xForwardedFor = HTTPField.Name("x-forwarded-for")!

    /// RFC 7239's standardized successor to `X-Forwarded-For`. Nothing here
    /// reads it — see `Docs/client-address.md` for why — but it is public
    /// so an application that wants it can, without reaching for a raw
    /// string.
    public static let forwarded = HTTPField.Name("forwarded")!
}
