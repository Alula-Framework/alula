import Crypto
import FlightSessions
import FlightTelemetry
import FlightWeb
import Foundation

/// Links that work once: password reset, email verification, magic sign-in.
///
/// ```swift
/// // Issuing — the raw token goes in the email, nowhere else.
/// let token = try await tokens.issue(
///     for: account.subject, purpose: .passwordReset, lifetime: .seconds(3600),
///     binding: account.passwordHash)
/// try await mailer.send(resetLink: "https://app.example.com/reset?token=\(token)")
///
/// // Redeeming — once.
/// let subject = try await tokens.redeem(token, purpose: .passwordReset) { subject in
///     try await accounts.find(subject: subject)?.passwordHash
/// }
/// ```
///
/// What this owns, so a flow built on it does not have to:
///
/// - **256 random bits**, base64url — nothing to guess and nothing to count
///   attempts against.
/// - **Only a digest is stored.** The store holds SHA-256 of the token, so a
///   leaked store, a backup or a log of its keys redeems nothing.
/// - **Single use, atomically.** Redeeming takes the record out of the store
///   in one step; two requests racing with one link get one success.
/// - **Purpose-bound.** An email-verification token is not a password-reset
///   token, whatever the caller passes.
/// - **Optionally state-bound.** `binding` is any string the token should
///   stop working once it changes. Bind a reset token to the current password
///   hash, and changing the password — by this link or any other way —
///   voids every reset link already sent. The binding is stored as a digest
///   too.
/// - **One answer for every failure.** Unknown, expired, used, wrong purpose,
///   stale binding: all ``OneTimeTokenError/invalidOrExpired``.
public struct OneTimeTokens: Sendable {
    /// What a token is for. A redemption for one purpose never accepts a
    /// token issued for another.
    public struct Purpose: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
        public let name: String
        public init(_ name: String) { self.name = name }
        public init(stringLiteral value: String) { self.init(value) }

        public static let passwordReset = Purpose("password-reset")
        public static let emailVerification = Purpose("email-verification")
        public static let magicLink = Purpose("magic-link")
    }

    private struct Record: Codable {
        let subject: String
        let purpose: Purpose
        let bindingDigest: String?
        let expiresAt: Date
    }

    private let store: any OneTimeTokenStore
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - store: Where the digests live — in memory, or Valkey across
    ///     replicas.
    ///   - now: The clock expiry is measured on.
    ///
    /// Issues and redemptions are reported as ``SignInEvents``.
    public init(store: any OneTimeTokenStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    /// A fresh token for `subject`. Return it to whoever delivers it — an
    /// email, usually — and do not keep it anywhere else.
    public func issue(
        for subject: String, purpose: Purpose, lifetime: Duration, binding: String? = nil
    ) async throws -> String {
        let token = Self.randomToken()
        let record = Record(
            subject: subject, purpose: purpose, bindingDigest: binding.map(Self.digest),
            expiresAt: now().addingTimeInterval(Double(lifetime.components.seconds)))
        try await store.put(Self.key(for: token), try JSONEncoder().encode(record), ttl: lifetime)
        Telemetry.emit(SignInEvents.TokenIssued.self) { .init(purpose: purpose.name) }
        return token
    }

    /// Redeems `token` for `purpose`, returning the subject it was issued to.
    /// The token is spent whether or not redemption succeeds.
    ///
    /// - Parameters:
    ///   - token: What the link carried.
    ///   - purpose: What this redemption is for; a token issued for any other
    ///     purpose is refused.
    ///   - currentBinding: The binding's value now, for the subject the token
    ///     names — the account's current password hash, say. Asked only when
    ///     the token was issued with a binding; a nil answer (the account is
    ///     gone) fails the redemption.
    /// - Throws: ``OneTimeTokenError/invalidOrExpired`` for every way a token
    ///   can be wrong.
    public func redeem(
        _ token: String, purpose: Purpose,
        currentBinding: (@Sendable (String) async throws -> String?)? = nil
    ) async throws -> String {
        func refuse(_ outcome: String) -> OneTimeTokenError {
            redeemed(purpose, outcome)
            return .invalidOrExpired
        }
        guard !token.isEmpty, token.count <= 128,
            let data = try await store.take(Self.key(for: token)),
            let record = try? JSONDecoder().decode(Record.self, from: data)
        else { throw refuse("unknown_or_used") }
        guard record.purpose == purpose else { throw refuse("wrong_purpose") }
        guard record.expiresAt > now() else { throw refuse("expired") }

        if let expected = record.bindingDigest {
            guard let currentBinding, let current = try await currentBinding(record.subject),
                Self.digest(current) == expected
            else { throw refuse("binding_mismatch") }
        }
        redeemed(purpose, "redeemed")
        return record.subject
    }

    private func redeemed(_ purpose: Purpose, _ outcome: String) {
        Telemetry.emit(SignInEvents.TokenRedemption.self) {
            .init(purpose: purpose.name, outcome: outcome)
        }
    }

    static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(
            Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    /// The store key: a digest, never the token.
    static func key(for token: String) -> String { "flight-ott:" + digest(token) }

    static func digest(_ value: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(value.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Why a token was not redeemed — deliberately one case. Which of unknown,
/// used, expired, wrong purpose or stale binding it was is nothing a caller
/// holding a link should learn.
public enum OneTimeTokenError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidOrExpired

    public var description: String { "one-time token invalid or expired" }
}

extension OneTimeTokenError: HTTPErrorRepresentable {
    public var httpStatus: HTTPResponse.Status { .badRequest }
    public var httpMessage: String { "This link is invalid or has expired" }
}
