import Crypto
import Foundation
import Synchronization

/// Long-lived keys for machine clients, sent as `Authorization: Bearer <key>`.
///
/// ```swift
/// // Issuing: show `issued.key` once, keep `issued.stored`.
/// let issued = APIKeys.issue(prefix: "sk", subject: "svc-billing", scopes: ["invoices:read"])
/// try await keys.save(issued.stored)
///
/// // Checking: provide it as the application's `any TokenValidator`.
/// let tokenValidator: any TokenValidator = APIKeyValidator(
///     store: keys, prefix: "sk", issuer: "https://app.example.com",
///     fallback: oidcValidator)   // everything else still goes to OIDC
/// ```
///
/// A key reads `sk_<id>_<secret>`. The prefix says what kind of credential it
/// is, to a person and to a secret scanner. The id is how it is found. The
/// secret is 256 random bits.
///
/// - **Only a digest is stored.** The store holds SHA-256 of the secret. The
///   secret is random and long, so a fast hash is enough; a slow password
///   hash would only cost CPU on every request.
/// - **Found by id, compared in constant time.** One store read per request,
///   and no timing difference between a wrong secret and a nearly right one.
/// - **Revocable and expiring.** A revoked or expired key is refused like an
///   unknown one.
/// - **One answer for every failure.** The client gets the generic 401. The
///   reason, never the key, goes to the log.
public enum APIKeys {
    /// A key as the store keeps it.
    public struct Stored: Sendable, Equatable, Codable {
        public var id: String
        /// SHA-256 of the secret, base64url.
        public var secretDigest: String
        public var subject: String
        public var roles: Set<String>
        public var scopes: Set<String>
        public var expiresAt: Date?
        public var revoked: Bool

        public init(
            id: String, secretDigest: String, subject: String, roles: Set<String> = [],
            scopes: Set<String> = [], expiresAt: Date? = nil, revoked: Bool = false
        ) {
            self.id = id
            self.secretDigest = secretDigest
            self.subject = subject
            self.roles = roles
            self.scopes = scopes
            self.expiresAt = expiresAt
            self.revoked = revoked
        }
    }

    /// A new key: `key` for its owner, shown once, and `stored` for the store.
    public struct Issued: Sendable {
        public let key: String
        public let stored: Stored
    }

    /// Makes a new key.
    ///
    /// - Parameters:
    ///   - prefix: Letters and digits, the same for every key the
    ///     ``APIKeyValidator`` checks.
    ///   - subject: Who the key acts as; becomes ``Principal/subject``.
    ///   - roles: Roles the principal carries.
    ///   - scopes: Scopes the principal carries.
    ///   - expiresAt: When it stops working; nil for never.
    public static func issue(
        prefix: String, subject: String, roles: Set<String> = [], scopes: Set<String> = [],
        expiresAt: Date? = nil
    ) -> Issued {
        precondition(isValidPrefix(prefix), "an API key prefix is letters and digits only")
        let id = randomBytes(8).map { String(format: "%02x", $0) }.joined()
        let secret = base64URL(Data(randomBytes(32)))
        return Issued(
            key: "\(prefix)_\(id)_\(secret)",
            stored: Stored(
                id: id, secretDigest: digest(secret), subject: subject, roles: roles,
                scopes: scopes, expiresAt: expiresAt))
    }

    /// The id and secret in `key`, when it has `prefix`'s shape.
    static func parse(_ key: String, prefix: String) -> (id: String, secret: String)? {
        guard key.hasPrefix(prefix + "_") else { return nil }
        let rest = key.dropFirst(prefix.count + 1)
        guard rest.count > 17 else { return nil }
        let id = rest.prefix(16)
        let separator = rest.index(rest.startIndex, offsetBy: 16)
        guard rest[separator] == "_", id.allSatisfy(\.isHexDigit) else { return nil }
        let secret = rest[rest.index(after: separator)...]
        guard secret.count <= 128 else { return nil }
        return (String(id), String(secret))
    }

    static func isValidPrefix(_ prefix: String) -> Bool {
        !prefix.isEmpty && prefix.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    static func digest(_ secret: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(secret.utf8))))
    }

    /// Compares every byte whatever the first mismatch.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8)
        let b = Array(b.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Where API keys are looked up. The application implements it over its own
/// table; ``InMemoryAPIKeyStore`` is for tests and prototypes.
public protocol APIKeyStore: Sendable {
    /// The key with `id`, or nil.
    func key(id: String) async throws -> APIKeys.Stored?
}

/// An ``APIKeyStore`` in memory.
public final class InMemoryAPIKeyStore: APIKeyStore, Sendable {
    private let keys = Mutex<[String: APIKeys.Stored]>([:])

    public init() {}

    public func save(_ key: APIKeys.Stored) {
        keys.withLock { $0[key.id] = key }
    }

    public func key(id: String) async throws -> APIKeys.Stored? {
        keys.withLock { $0[id] }
    }
}

/// Checks API keys issued by ``APIKeys/issue(prefix:subject:roles:scopes:expiresAt:)``.
///
/// A bearer token without this validator's prefix is not an API key, and goes
/// to `fallback` when there is one, so keys for machines and OIDC tokens for
/// people can share one `Authorization` header.
public struct APIKeyValidator: TokenValidator {
    private let store: any APIKeyStore
    private let prefix: String
    private let issuer: String
    private let fallback: (any TokenValidator)?
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - store: Where keys are looked up.
    ///   - prefix: The prefix every key was issued with.
    ///   - issuer: ``Principal/issuer`` for principals this produces.
    ///   - fallback: What checks a bearer token without the prefix. Nil
    ///     refuses it.
    ///   - now: The clock expiry is measured on.
    public init(
        store: any APIKeyStore, prefix: String, issuer: String,
        fallback: (any TokenValidator)? = nil, now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(APIKeys.isValidPrefix(prefix), "an API key prefix is letters and digits only")
        self.store = store
        self.prefix = prefix
        self.issuer = issuer
        self.fallback = fallback
        self.now = now
    }

    public func validate(_ token: String) async throws -> Principal {
        guard token.hasPrefix(prefix + "_") else {
            if let fallback { return try await fallback.validate(token) }
            throw TokenValidationError(kind: .malformedToken, reason: "not an API key")
        }
        guard let (id, secret) = APIKeys.parse(token, prefix: prefix) else {
            throw TokenValidationError(kind: .malformedToken, reason: "API key is malformed")
        }
        guard let stored = try await store.key(id: id),
            APIKeys.constantTimeEquals(stored.secretDigest, APIKeys.digest(secret))
        else {
            throw TokenValidationError(
                kind: .signatureInvalid, reason: "unknown API key or wrong secret (id \(id))")
        }
        guard !stored.revoked else {
            throw TokenValidationError(kind: .signatureInvalid, reason: "API key \(id) is revoked")
        }
        if let expiresAt = stored.expiresAt, expiresAt <= now() {
            throw TokenValidationError(kind: .expired, reason: "API key \(id) has expired")
        }
        return Principal(
            subject: stored.subject, issuer: issuer, roles: stored.roles, scopes: stored.scopes,
            claims: ["api_key_id": id])
    }
}
