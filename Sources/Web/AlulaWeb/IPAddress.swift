#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// A parsed IPv4 or IPv6 address, kept only to answer one question:
/// is this address inside that configured range. Not a general networking
/// type — no DNS, no zone ids, no scope, no formatting back to a string.
/// ``PeerAddress`` already carries the string form wherever one exists;
/// this exists purely for `CIDRBlock.contains(_:)`.
///
/// Parsing goes through the platform's own `inet_pton` rather than a
/// hand-rolled parser. IPv6's compressed forms (`::`, `::1`,
/// `2001:db8::a:b`) have enough edge cases that betting on libc, which
/// every other piece of server software on the box already trusts for
/// this, is the safer choice than betting on a parser written for this
/// one purpose.
struct IPAddress: Sendable, Equatable, Hashable {
    /// 4 bytes for IPv4, 16 for IPv6, always network order.
    let bytes: [UInt8]

    /// `nil` for anything that is not a literal IPv4 or IPv6 address —
    /// never a hostname, and never partially valid.
    init?(_ string: String) {
        var v4 = [UInt8](repeating: 0, count: 4)
        if string.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            self.bytes = v4
            return
        }
        var v6 = [UInt8](repeating: 0, count: 16)
        guard string.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 else {
            return nil
        }
        // IPv4-mapped IPv6 (`::ffff:a.b.c.d`) is normalized to plain IPv4
        // here. A dual-stack listener reports an IPv4 peer exactly this
        // way, and a trusted-proxy list written in the IPv4 CIDR form an
        // operator actually has — straight from their cloud provider's
        // docs — would otherwise never match: the comparison would fail
        // in the safe direction (never trusted) but not the intended one,
        // and "my load balancer's own subnet isn't trusted" is a
        // confusing thing to debug.
        if v6[0..<10].allSatisfy({ $0 == 0 }), v6[10] == 0xFF, v6[11] == 0xFF {
            self.bytes = Array(v6[12..<16])
        } else {
            self.bytes = v6
        }
    }

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var bitCount: Int { bytes.count * 8 }
}

/// An address range in CIDR notation (`"10.0.0.0/8"`), or a single address
/// as its narrowest block (`"203.0.113.5/32"`).
struct CIDRBlock: Sendable, Equatable {
    let base: IPAddress
    let prefixLength: Int

    /// `nil` for anything that is not `<address>/<prefix>`, an address
    /// that does not parse, or a prefix out of range for that address's
    /// family (0...32 for IPv4, 0...128 for IPv6).
    init?(_ string: String) {
        let parts = string.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let address = IPAddress(String(parts[0])),
            let prefixLength = Int(parts[1]), (0...address.bitCount).contains(prefixLength)
        else { return nil }
        self.base = address
        self.prefixLength = prefixLength
    }

    /// Whether `candidate` falls inside this block. Different address
    /// families never match — a /8 written in IPv4 says nothing about any
    /// IPv6 address, including one that happens to embed the same bytes.
    func contains(_ candidate: IPAddress) -> Bool {
        guard base.bytes.count == candidate.bytes.count else { return false }
        let fullBytes = prefixLength / 8
        let remainingBits = prefixLength % 8
        if fullBytes > 0 {
            guard base.bytes[..<fullBytes].elementsEqual(candidate.bytes[..<fullBytes]) else {
                return false
            }
        }
        guard remainingBits > 0 else { return true }
        let mask = ~UInt8(0) << (8 - remainingBits)
        return (base.bytes[fullBytes] & mask) == (candidate.bytes[fullBytes] & mask)
    }
}
