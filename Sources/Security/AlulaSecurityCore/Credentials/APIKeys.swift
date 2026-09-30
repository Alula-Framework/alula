import AlulaSupport
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
/// // Checking: list AlulaAPIKeyModule and provide `any APIKeyStore`. Keys go
/// // to it; every other bearer token still goes to AlulaOIDCModule, or to
/// // whatever `any TokenValidator` the application has.
/// modules: [AlulaOIDCModule.self, AlulaAPIKeyModule.self, AppModule.self]
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
    /// A key as the store keeps it. Holds no secret:
    /// ``APIKeys/Stored/id`` is not one (it is in every key, in the clear)
    /// and ``APIKeys/Stored/secretDigest`` cannot be presented as a key.
    public struct Stored: Sendable, Equatable, Codable {
        /// The key's lookup id, the middle part of `sk_<id>_<secret>`.
        public var id: String
        /// SHA-256 of the secret, base64url.
        public var secretDigest: String
        /// The ``Principal/subject`` a request with this key gets.
        public var subject: String
        /// The ``Principal/roles`` a request with this key gets.
        public var roles: Set<String>
        /// The ``Principal/scopes`` a request with this key gets.
        public var scopes: Set<String>
        /// When the key stops working; nil for never. Compared with the
        /// validator's clock, with no leeway.
        public var expiresAt: Date?
        /// Set it to refuse the key from the next request the store answers
        /// with it: ``APIKeyValidator`` keeps no cache of its own.
        public var revoked: Bool

        /// A stored key from its parts. ``APIKeys/issue(prefix:subject:roles:scopes:expiresAt:)``
        /// builds one for a new key; this is for a store reading its rows.
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
        /// The whole key, secret included. Give it to its owner once; it is
        /// not kept anywhere.
        public let key: String
        /// What to save in the ``APIKeyStore``.
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
        let id = SecureRandom.bytes(8).map { String(format: "%02x", $0) }.joined()
        let secret = SecureRandom.token()
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
        SHA256Digest.base64URL(secret)
    }
}

/// Where API keys are looked up. The application implements it over its own
/// table; ``InMemoryAPIKeyStore`` is for tests and prototypes.
public protocol APIKeyStore: Sendable {
    /// The key with `id`, or nil. Called once per request that presents a
    /// well-formed key, before the secret is compared.
    ///
    /// Return revoked and expired keys as they are — ``APIKeyValidator``
    /// refuses them — and throw when the store cannot answer. A throw is
    /// not a 5xx: authentication treats it as a failed credential, so every
    /// API-key client gets `401` for the length of the outage.
    func key(id: String) async throws -> APIKeys.Stored?
}

/// An ``APIKeyStore`` in memory.
public final class InMemoryAPIKeyStore: APIKeyStore, Sendable {
    private let keys = Mutex<[String: APIKeys.Stored]>([:])

    /// An empty store.
    public init() {}

    /// Adds `key`, or replaces the key with its id.
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

    /// This validator as a ``TokenStrategy``: it recognizes tokens with its
    /// prefix, so it composes with the application's other validators.
    public var strategy: TokenStrategy {
        let prefix = prefix
        return TokenStrategy("api-keys (\(prefix)_)", recognizes: { $0.hasPrefix(prefix + "_") }, validator: self)
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
            ConstantTime.equals(stored.secretDigest, APIKeys.digest(secret))
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
