import Foundation

/// The JOSE header fields Alula needs *before* verification: `kid` decides
/// whether a JWKS refresh is warranted, `alg` is screened
/// defensively. This is structural parsing only — no cryptography; signature
/// verification stays with JWTKit.
struct TokenHeader: Sendable, Equatable {
    let algorithm: String?
    let keyID: String?

    private struct Fields: Decodable {
        let alg: String?
        let kid: String?
    }

    /// Shared: `parse` runs on every token validation, which is every
    /// authenticated request, and the decoder is configured with nothing —
    /// so a fresh one per request bought an allocation and no behaviour.
    private static let headerDecoder = JSONDecoder()

    static func parse(_ token: String) throws(TokenValidationError) -> TokenHeader {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else {
            throw TokenValidationError(
                kind: .malformedToken,
                reason: "expected 3 JWT segments, got \(segments.count)"
            )
        }
        guard let headerData = Data(base64URLEncoded: segments[0]) else {
            throw TokenValidationError(
                kind: .malformedToken, reason: "JOSE header is not valid base64url"
            )
        }
        guard let fields = try? Self.headerDecoder.decode(Fields.self, from: headerData) else {
            throw TokenValidationError(
                kind: .malformedToken, reason: "JOSE header is not a valid JSON object"
            )
        }
        return TokenHeader(algorithm: fields.alg, keyID: fields.kid)
    }
}

extension Data {
    init?(base64URLEncoded input: Substring) {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        self.init(base64Encoded: base64)
    }
}
