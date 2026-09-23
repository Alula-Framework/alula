import AlulaSessions

/// The token this session's state-changing requests must carry, and the
/// place it lives.
///
/// The synchronizer pattern: the value exists once, server-side, in the
/// session — not in a second cookie, the way the double-submit variant
/// needs. A response hands it to whatever will submit the next unsafe
/// request, the application's own choice how: a hidden form field, a
/// `<meta>` tag a script reads, a field in a JSON body. Nothing here
/// prescribes that part, because it depends entirely on what the response
/// is.
extension Session {
    private static let csrfTokenKey = "alula.csrf-token"

    /// The token to embed in whatever this response is about to send —
    /// generated once, on first call, and stored for the rest of the
    /// session's life. Safe to call from a request that will not write
    /// anything else: like every other `Session` write, nothing is
    /// persisted until the request actually modifies something, and
    /// calling this is exactly that.
    public func csrfToken() throws -> String {
        if let existing = try get(Self.csrfTokenKey, as: String.self) {
            return existing
        }
        let token = CSRFToken.generate()
        try set(Self.csrfTokenKey, token)
        return token
    }
}

enum CSRFToken {
    /// 256 bits, unpadded base64url — the same shape `SessionID.generate()`
    /// produces, from the same `SystemRandomNumberGenerator`. A second,
    /// independent implementation rather than a shared one: a session id
    /// and a CSRF token are different values with different lifetimes, and
    /// the thirty lines this duplicates are cheap next to the coupling
    /// importing one from the other would add.
    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        for _ in 0..<4 {
            let word = UInt64.random(in: .min ... .max, using: &generator)
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: word >> UInt64(shift)))
            }
        }
        return base64url(bytes)
    }

    private static let alphabet = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    private static func base64url(_ bytes: [UInt8]) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(43)
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

    /// Whether `provided` is the same string as `expected`, in time that
    /// does not depend on *where* they first differ.
    ///
    /// A plain `==` short-circuits at the first mismatched byte, which
    /// leaks exactly enough through response timing for an attacker to
    /// recover a valid token one byte at a time — the classic argument for
    /// every constant-time comparison anywhere in cryptography. This
    /// compares every byte unconditionally and only inspects the
    /// accumulated result at the end, so a guess that is right in the
    /// first byte and a guess that is right in none of them take
    /// indistinguishable time.
    static func matches(_ provided: String, _ expected: String) -> Bool {
        let providedBytes = Array(provided.utf8)
        let expectedBytes = Array(expected.utf8)
        guard providedBytes.count == expectedBytes.count else { return false }
        var difference: UInt8 = 0
        for index in providedBytes.indices {
            difference |= providedBytes[index] ^ expectedBytes[index]
        }
        return difference == 0
    }
}
