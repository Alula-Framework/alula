// Rules Alula implemented more than once, kept here once. Internal to the
// package — no product, `package` access — and standard library only, so a
// Foundation-free file in any target can use it. The Foundation-dependent
// helpers are next door, in AlulaSupportFoundation.

/// Bytes from the system's cryptographic generator.
package enum SecureRandom {
    /// `count` bytes from `SystemRandomNumberGenerator`, which is
    /// cryptographically secure on every platform Swift ships on.
    package static func bytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        while bytes.count < count {
            let word = generator.next()
            for shift in stride(from: 56, through: 0, by: -8) where bytes.count < count {
                bytes.append(UInt8(truncatingIfNeeded: word >> UInt64(shift)))
            }
        }
        return bytes
    }

    /// `byteCount` random bytes as unpadded base64url — 32 bytes, the
    /// default, is 256 bits in 43 characters: a session id, a CSRF token, a
    /// PKCE verifier, a one-time link.
    package static func token(byteCount: Int = 32) -> String {
        Base64URL.encode(bytes(byteCount))
    }
}

/// Unpadded base64url (RFC 4648 §5).
///
/// Hand-rolled rather than Foundation's `base64EncodedString` plus three
/// replacements: it is a dozen lines, and it keeps a caller free of
/// Foundation.
package enum Base64URL {
    private static let alphabet = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    package static func encode(_ input: some Sequence<UInt8>) -> String {
        let bytes = Array(input)
        var output: [UInt8] = []
        output.reserveCapacity((bytes.count * 4 + 2) / 3)
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

/// Comparison whose time does not depend on where two secrets first differ.
package enum ConstantTime {
    /// Whether `a` and `b` are the same bytes.
    ///
    /// A plain `==` stops at the first mismatched byte, which leaks through
    /// response timing enough to recover a secret one byte at a time. This
    /// compares every byte unconditionally and inspects the accumulated
    /// result only at the end. The length is not hidden; every secret
    /// compared here has a fixed length.
    package static func equals(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8)
        let b = Array(b.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}
