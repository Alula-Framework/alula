import AlulaSupport
import Crypto
import Foundation

/// SHA-256 of a string's UTF-8, as unpadded base64url: the stored form of an
/// API key's secret and of a one-time token, and a PKCE challenge
/// (RFC 7636 §4.2).
enum SHA256Digest {
    static func base64URL(_ value: String) -> String {
        Base64URL.encode(SHA256.hash(data: Data(value.utf8)))
    }
}
