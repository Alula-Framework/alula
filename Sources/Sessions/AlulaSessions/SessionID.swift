/// The key a session is stored under, and the value its cookie carries.
///
/// 256 bits from the system's cryptographic generator, spelled as 43
/// characters of unpadded base64url. That is the whole design: an id with
/// this much entropy cannot be guessed, so it needs no signature, and a store
/// keyed by it needs no second check before trusting a lookup. The other
/// design — a signed cookie carrying the state itself — has a 4 KB ceiling,
/// no way to revoke, and a key to rotate; it is deliberately not what this
/// is.
///
/// An id is a bearer credential. Its `description` is redacted so that a
/// stray `"\(session.id)"` in a log line does not hand out the session; the
/// cookie value is spelled ``cookieValue`` on purpose, so reaching for the
/// full string is a visible act.
public struct SessionID: Hashable, Sendable {
    /// Bytes of entropy behind every generated id.
    public static let byteCount = 32
    /// `byteCount` bytes in unpadded base64url: ⌈32 × 4 ÷ 3⌉.
    static let encodedLength = 43

    /// The id as the cookie carries it.
    public let cookieValue: String

    private init(unchecked cookieValue: String) {
        self.cookieValue = cookieValue
    }

    /// A fresh id from `SystemRandomNumberGenerator`, which is
    /// cryptographically secure on every platform Swift ships on.
    public static func generate() -> SessionID {
        var generator = SystemRandomNumberGenerator()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(byteCount)
        for _ in 0..<(byteCount / 8) {
            let word = UInt64.random(in: .min ... .max, using: &generator)
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: word >> UInt64(shift)))
            }
        }
        return SessionID(unchecked: base64url(bytes))
    }

    /// Parses a cookie value. `nil` for anything that is not the exact shape
    /// ``generate()`` produces — the wrong length, or a character outside the
    /// base64url alphabet — so a store is never asked about garbage, and a
    /// tampered or truncated cookie reads as "no session" rather than as a
    /// failure.
    public init?(cookieValue: String) {
        guard cookieValue.utf8.count == Self.encodedLength,
            cookieValue.utf8.allSatisfy(Self.isBase64URL)
        else { return nil }
        self.cookieValue = cookieValue
    }

    private static func isBase64URL(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
            return true
        default:
            return false
        }
    }

    private static let alphabet = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    /// Unpadded base64url. Hand-rolled rather than Foundation's
    /// `base64EncodedString` plus two replacements and a trim: it is eleven
    /// lines, runs once per new session, and keeps this target free of
    /// Foundation.
    private static func base64url(_ bytes: [UInt8]) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(encodedLength)
        var index = 0
        while index < bytes.count {
            let first = bytes[index]
            let second = index + 1 < bytes.count ? bytes[index + 1] : 0
            let third = index + 2 < bytes.count ? bytes[index + 2] : 0
            output.append(alphabet[Int(first >> 2)])
            output.append(alphabet[Int((first & 0x03) << 4 | second >> 4)])
            if index + 1 < bytes.count {
                output.append(alphabet[Int((second & 0x0F) << 2 | third >> 6)])
            }
            if index + 2 < bytes.count {
                output.append(alphabet[Int(third & 0x3F)])
            }
            index += 3
        }
        return String(decoding: output, as: UTF8.self)
    }
}

extension SessionID: CustomStringConvertible {
    /// The first eight characters and an ellipsis — enough to correlate two
    /// log lines, not enough to use.
    public var description: String {
        "\(cookieValue.prefix(8))…"
    }
}
