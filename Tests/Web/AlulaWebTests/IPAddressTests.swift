import Testing

@testable import AlulaWeb

@Suite("IPAddress")
struct IPAddressTests {

    @Test("IPv4 parses to 4 bytes")
    func ipv4() throws {
        let address = try #require(IPAddress("203.0.113.7"))
        #expect(address.bytes == [203, 0, 113, 7])
        #expect(address.bitCount == 32)
    }

    @Test("IPv6 parses to 16 bytes, including the compressed forms")
    func ipv6() throws {
        let loopback = try #require(IPAddress("::1"))
        #expect(loopback.bytes == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
        #expect(loopback.bitCount == 128)

        // 2001:0db8:0000:0000:0000:0000:000a:000b
        let full = try #require(IPAddress("2001:db8::a:b"))
        #expect(full.bytes[0] == 0x20 && full.bytes[1] == 0x01)
        #expect(full.bytes[2] == 0x0D && full.bytes[3] == 0xB8)
        #expect(Array(full.bytes[4..<12]).allSatisfy { $0 == 0 })
        #expect(full.bytes[12] == 0 && full.bytes[13] == 0x0A)
        #expect(full.bytes[14] == 0 && full.bytes[15] == 0x0B)
    }

    @Test("an IPv4-mapped IPv6 address normalizes to plain IPv4")
    func ipv4MappedNormalizes() throws {
        let mapped = try #require(IPAddress("::ffff:10.0.0.5"))
        let plain = try #require(IPAddress("10.0.0.5"))
        #expect(
            mapped == plain,
            "a dual-stack listener's IPv4-mapped form must compare equal to the plain form")
        #expect(mapped.bytes == [10, 0, 0, 5])
    }

    @Test("ffff in the right two bytes is not enough; the other 80 bits must be zero too")
    func onlyTheExactMappingPrefixNormalizes() throws {
        // 0001:0000:0000:0000:0000:ffff:0a00:0005 — 0xffff sits in exactly
        // the group RFC 4291's mapped form requires, but the leading group
        // is 0001, not 0000, so this is not that form and must not be
        // treated as one.
        let notMapped = try #require(IPAddress("1::ffff:a00:5"))
        #expect(
            notMapped.bitCount == 128, "the leading bits must all be zero for the mapping to apply")
    }

    @Test("garbage, a bare hostname, and an out-of-range octet all fail to parse")
    func rejectsGarbage() {
        #expect(IPAddress("") == nil)
        #expect(IPAddress("not-an-address") == nil)
        #expect(IPAddress("example.com") == nil)
        #expect(IPAddress("999.0.0.1") == nil)
        #expect(IPAddress("10.0.0") == nil, "an incomplete IPv4 literal is not padded, not guessed")
        #expect(IPAddress("10.0.0.1.2") == nil)
        #expect(IPAddress(":::") == nil)
    }

    @Test("two addresses with the same bytes are equal regardless of how they were spelled")
    func equality() throws {
        #expect(try #require(IPAddress("127.0.0.1")) == (try #require(IPAddress("127.0.0.1"))))
        #expect(try #require(IPAddress("::1")) == (try #require(IPAddress("0:0:0:0:0:0:0:1"))))
    }
}

@Suite("CIDRBlock")
struct CIDRBlockTests {

    @Test("a /8 contains every address sharing its first octet, and nothing else")
    func classfulPrefix() throws {
        let block = try #require(CIDRBlock("10.0.0.0/8"))
        #expect(block.contains(try #require(IPAddress("10.0.0.1"))))
        #expect(block.contains(try #require(IPAddress("10.255.255.255"))))
        #expect(!block.contains(try #require(IPAddress("11.0.0.1"))))
        #expect(!block.contains(try #require(IPAddress("9.255.255.255"))))
    }

    @Test("a prefix that does not land on a byte boundary still masks correctly")
    func nonByteAlignedPrefix() throws {
        // 10.0.0.0/12 covers 10.0.0.0 through 10.15.255.255.
        let block = try #require(CIDRBlock("10.0.0.0/12"))
        #expect(block.contains(try #require(IPAddress("10.15.255.255"))))
        #expect(!block.contains(try #require(IPAddress("10.16.0.0"))))
    }

    @Test("/32 and /128 are exact single addresses")
    func exactSingleAddresses() throws {
        let v4 = try #require(CIDRBlock("203.0.113.5/32"))
        #expect(v4.contains(try #require(IPAddress("203.0.113.5"))))
        #expect(!v4.contains(try #require(IPAddress("203.0.113.6"))))

        let v6 = try #require(CIDRBlock("2001:db8::1/128"))
        #expect(v6.contains(try #require(IPAddress("2001:db8::1"))))
        #expect(!v6.contains(try #require(IPAddress("2001:db8::2"))))
    }

    @Test("/0 contains every address of its own family")
    func zeroPrefixContainsEverything() throws {
        let v4 = try #require(CIDRBlock("0.0.0.0/0"))
        #expect(v4.contains(try #require(IPAddress("255.255.255.255"))))
        let v6 = try #require(CIDRBlock("::/0"))
        #expect(v6.contains(try #require(IPAddress("ffff::1"))))
    }

    @Test("a v4 block never contains a v6 address, even one embedding the same bytes")
    func familiesNeverCross() throws {
        let block = try #require(CIDRBlock("10.0.0.0/8"))
        #expect(!block.contains(try #require(IPAddress("::a:0:0:1"))))
    }

    @Test("an IPv6 block matches an IPv4-mapped address, because parsing already normalized it")
    func ipv6BlockMatchesNormalizedMapping() throws {
        // Written as a /8 in IPv4 form — the shape an operator's cloud
        // provider actually publishes — and it must still match a peer
        // NIO reports as IPv4, not the mapped IPv6 spelling.
        let block = try #require(CIDRBlock("10.0.0.0/8"))
        #expect(block.contains(try #require(IPAddress("::ffff:10.1.2.3"))))
    }

    @Test("malformed CIDR strings, and a prefix out of range for the family, are refused")
    func rejectsMalformed() {
        #expect(CIDRBlock("10.0.0.0") == nil, "no prefix at all")
        #expect(CIDRBlock("10.0.0.0/8/8") == nil)
        #expect(CIDRBlock("not-an-address/8") == nil)
        #expect(CIDRBlock("10.0.0.0/33") == nil, "past 32 for IPv4")
        #expect(CIDRBlock("::/129") == nil, "past 128 for IPv6")
        #expect(CIDRBlock("10.0.0.0/-1") == nil)
    }
}
