import AlulaSupport
import AlulaSupportFoundation
import Foundation
import Testing

@Suite("Tokens")
struct TokenTests {
    @Test("base64url is RFC 4648 §5, unpadded", arguments: [
        ("", ""), ("f", "Zg"), ("fo", "Zm8"), ("foo", "Zm9v"), ("foob", "Zm9vYg"),
        ("fooba", "Zm9vYmE"), ("foobar", "Zm9vYmFy"),
    ])
    func base64URLVectors(input: String, expected: String) {
        #expect(Base64URL.encode(Array(input.utf8)) == expected)
    }

    @Test("base64url uses - and _ where base64 has + and /")
    func base64URLAlphabet() {
        #expect(Base64URL.encode([0xFB, 0xFF, 0xBF]) == "-_-_")
        #expect(Base64URL.encode(Data([0xFB, 0xFF])) == "-_8")
    }

    @Test("a token is 43 base64url characters from 32 fresh bytes")
    func tokens() {
        #expect(SecureRandom.bytes(0).isEmpty)
        #expect(SecureRandom.bytes(13).count == 13)
        let token = SecureRandom.token()
        #expect(token.count == 43)
        #expect(token.utf8.allSatisfy { byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
        })
        #expect(Set((0..<64).map { _ in SecureRandom.token() }).count == 64)
    }

    @Test("constant-time equality is equality")
    func constantTime() {
        #expect(ConstantTime.equals("abc", "abc"))
        #expect(ConstantTime.equals("", ""))
        #expect(!ConstantTime.equals("abc", "abd"))
        #expect(!ConstantTime.equals("abc", "abcd"))
    }
}

@Suite("Duration")
struct DurationSupportTests {
    @Test("seconds keep their fraction")
    func inSeconds() {
        #expect(Duration.milliseconds(500).inSeconds == 0.5)
        #expect(Duration.milliseconds(1500).inSeconds == 1.5)
        #expect(Duration.seconds(-2).inSeconds == -2)
    }

    @Test("whole seconds round up, and nothing left is 0", arguments: [
        (Duration.zero, Int64(0)), (.milliseconds(-400), 0), (.milliseconds(400), 1),
        (.seconds(1), 1), (.milliseconds(1001), 2), (.seconds(90), 90),
    ])
    func roundedUp(duration: Duration, expected: Int64) {
        #expect(duration.wholeSecondsRoundedUp == expected)
    }
}

@Suite("Bounded eviction")
struct BoundedEvictionTests {
    @Test("within the bound nothing goes")
    func withinBound() {
        var map = ["a": 1, "b": 2]
        BoundedEviction.enforce(&map, maxEntries: 2, isExpired: { _ in true }, order: { $0 })
        #expect(map.count == 2)
    }

    @Test("expired entries go first, and may be enough")
    func expiredFirst() {
        var map = ["old": 1, "a": 10, "b": 20]
        BoundedEviction.enforce(&map, maxEntries: 2, isExpired: { $0 < 5 }, order: { $0 })
        #expect(map == ["a": 10, "b": 20])
    }

    @Test("then the first in order, in a batch of a sixteenth of the bound")
    func batch() {
        var map = Dictionary(uniqueKeysWithValues: (0..<33).map { ("k\($0)", $0) })
        BoundedEviction.enforce(&map, maxEntries: 32, isExpired: { _ in false }, order: { $0 })
        #expect(map.count == 30)
        #expect(map["k0"] == nil && map["k1"] == nil && map["k2"] == nil)
        #expect(map["k3"] == 3)
    }
}

@Suite("URL support")
struct URLSupportTests {
    @Test(
        "loopback, however it is spelled",
        arguments: [
            "http://localhost:8080", "http://LOCALHOST", "http://LocalHost/x", "http://127.0.0.1:1",
            "http://[::1]:8080", "http://app.localhost", "http://App.LOCALHOST:3000",
        ])
    func loopback(url: String) throws {
        #expect(try #require(URL(string: url)).hostIsLoopback)
    }

    @Test(
        "not loopback",
        arguments: [
            "http://example.com", "http://localhost.example.com", "http://127.0.0.2",
            "http://notlocalhost", "file:///tmp/x",
        ])
    func notLoopback(url: String) throws {
        #expect(!(try #require(URL(string: url)).hostIsLoopback))
    }

    @Test("redaction drops the query and the userinfo, and keeps the rest")
    func redaction() throws {
        let url = try #require(URL(string: "wss://ada:hunter2@example.com:8443/socket?token=abc"))
        #expect(url.redactedForLog == "wss://example.com:8443/socket")
        let plain = try #require(URL(string: "https://example.com/a/b"))
        #expect(plain.redactedForLog == "https://example.com/a/b")
    }
}

@Suite("Form encoding")
struct FormEncodingTests {
    @Test("unreserved ASCII stays; everything else is percent-encoded UTF-8")
    func encoding() {
        #expect(FormEncoding.encode("AZaz09-._~") == "AZaz09-._~")
        #expect(FormEncoding.encode("a b+c&d=e") == "a%20b%2Bc%26d%3De")
        #expect(FormEncoding.encode("façade") == "fa%C3%A7ade")
        #expect(FormEncoding.encode("秘密") == "%E7%A7%98%E5%AF%86")
        #expect(FormEncoding.encode("٣") == "%D9%A3", "a non-ASCII digit too")
        #expect(FormEncoding.encode([("k", "v 1"), ("é", "x")]) == "k=v%201&%C3%A9=x")
    }

    @Test("Basic credentials form-encode each half before the colon")
    func basic() {
        let expected = Data("a%3Ab:p%25%C3%A9".utf8).base64EncodedString()
        #expect(FormEncoding.basicAuthorization(user: "a:b", password: "p%é") == "Basic \(expected)")
    }
}

@Suite("HTTP dates")
struct HTTPDateCodecTests {
    @Test("the three forms parse to the same instant, and format round-trips")
    func forms() throws {
        let expected = Date(timeIntervalSince1970: 784_111_777)
        #expect(HTTPDateCodec.parse("Sun, 06 Nov 1994 08:49:37 GMT") == expected)
        #expect(HTTPDateCodec.parse("Sunday, 06-Nov-94 08:49:37 GMT") == expected)
        #expect(HTTPDateCodec.parse("Sun Nov  6 08:49:37 1994") == expected)
        #expect(HTTPDateCodec.format(expected) == "Sun, 06 Nov 1994 08:49:37 GMT")
    }
}
