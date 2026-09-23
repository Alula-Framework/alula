import CoreMetrics
import FlightRateLimit
import FlightWeb
import Foundation
import Logging
import Synchronization

/// Checks an identifier and password against a ``CredentialStore`` and
/// answers with a ``Principal`` — the same type every other sign-in path
/// produces, carrying the same ``Principal/StandardClaim``s.
///
/// ```swift
/// let authenticator = PasswordAuthenticator(
///     store: accounts, issuer: "https://app.example.com", limiter: limiter)
/// let principal = try await authenticator.authenticate(
///     identifier: form.email, password: form.password,
///     clientAddress: context.clientAddress?.host)
/// try context.requireSession().signIn(principal)
/// ```
///
/// Password sign-in is short to write and easy to get subtly wrong. This type
/// exists so the subtle parts are written once:
///
/// - **Throttled before hashing.** Per identifier and per client address,
///   through the application's `RateLimiter` — a refused attempt costs no
///   Argon2 work, so the throttle is also what stops a flood of sign-ins
///   from spending the server's CPU on hashes.
/// - **The same work for an account that does not exist.** An unknown
///   identifier is verified against a dummy hash made with the current
///   parameters, so response time does not say which accounts are real.
/// - **One answer for every wrong guess.** Unknown account, no password,
///   wrong password: all ``PasswordAuthenticationError/invalidCredentials``.
///   A disabled account is only reported once its password has verified.
/// - **Normalized input.** The identifier is trimmed and NFC-normalized; so
///   is the password, as NIST SP 800-63B-4 §3.1.1.2 recommends, so the same
///   password typed on two keyboards hashes the same. 0.31 and 0.32
///   normalized passwords with NFKC, following the earlier revision; a
///   password whose NFKC form differs from its NFC form (compatibility
///   characters: ligatures, full-width forms) is verified against the old
///   form when the new one fails, and rehashed under NFC when it matches.
///   ASCII is unchanged by either form.
/// - **Stronger hashes over time.** A stored hash made under weaker
///   parameters is replaced after a successful sign-in — the only moment the
///   plaintext is available.
public struct PasswordAuthenticator: Sendable {

    /// How many attempts are allowed before sign-in answers 429.
    ///
    /// Both limits count every attempt, successful or not — GCRA has no
    /// notion of "forgive on success", and a budget generous enough for
    /// honest mistakes is also generous enough that counting successes does
    /// not matter.
    public struct Throttle: Sendable, Equatable {
        /// Attempts against one identifier from anywhere: the limit a
        /// targeted guess against one account runs into.
        public var perIdentifier: RateLimitQuota
        /// Attempts from one client address across any identifiers: the limit
        /// credential stuffing runs into.
        public var perAddress: RateLimitQuota

        public init(perIdentifier: RateLimitQuota, perAddress: RateLimitQuota) {
            self.perIdentifier = perIdentifier
            self.perAddress = perAddress
        }

        /// Ten per identifier per fifteen minutes; sixty per address per
        /// fifteen minutes. An address behind a shared NAT is the case the
        /// second number is sized for.
        public static let `default` = Throttle(
            perIdentifier: RateLimitQuota(permits: 10, per: .seconds(15 * 60)),
            perAddress: RateLimitQuota(permits: 60, per: .seconds(15 * 60)))
    }

    private let store: any CredentialStore
    private let hasher: any PasswordHashing
    private let limiter: RateLimiter
    private let throttle: Throttle
    private let issuer: String
    private let logger: Logger
    private let dummyHash: DummyHash
    private let metrics: any MetricsFactory

    /// - Parameters:
    ///   - store: Where accounts are looked up.
    ///   - issuer: ``Principal/issuer`` for principals this produces — the
    ///     application's own URL is the natural value. Distinguishes a
    ///     locally authenticated principal from one an external provider
    ///     asserted.
    ///   - hasher: How passwords are hashed. Argon2id with OWASP's defaults
    ///     unless given another.
    ///   - limiter: The application's rate limiter — from
    ///     `FlightRateLimitModule`, so a Valkey-backed store limits across
    ///     replicas.
    ///   - throttle: The two budgets. ``Throttle/default`` unless given one.
    ///   - logger: Where store and throttle failures, and failed hash
    ///     upgrades, are reported. Never the password or the hash.
    ///   - metrics: Where ``SignInMetrics`` counters go; the bootstrapped
    ///     `MetricsSystem` when nil.
    public init(
        store: any CredentialStore,
        issuer: String,
        hasher: any PasswordHashing = Argon2idHashing(),
        limiter: RateLimiter,
        throttle: Throttle = .default,
        logger: Logger = Logger(label: "flight.security.password"),
        metrics: (any MetricsFactory)? = nil
    ) {
        self.metrics = metrics ?? MetricsSystem.factory
        self.store = store
        self.issuer = issuer
        self.hasher = hasher
        self.limiter = limiter
        self.throttle = throttle
        self.logger = logger
        self.dummyHash = DummyHash(hasher: hasher)
    }

    /// The principal for `identifier`, if `password` is theirs.
    ///
    /// - Parameters:
    ///   - rawIdentifier: What the user typed to name their account; trimmed
    ///     and NFC-normalized before the store sees it.
    ///   - password: What they typed as the password; NFC-normalized.
    ///   - clientAddress: Where the attempt came from —
    ///     `context.clientAddress?.host`. Nil skips the per-address budget;
    ///     the per-identifier one always applies.
    /// - Throws: ``PasswordAuthenticationError``, and nothing else.
    public func authenticate(
        identifier rawIdentifier: String, password: String, clientAddress: String?
    ) async throws -> Principal {
        do {
            let principal = try await authenticateUncounted(
                identifier: rawIdentifier, password: password, clientAddress: clientAddress)
            SignInMetrics.attempt("password", "success", metrics)
            return principal
        } catch let error as PasswordAuthenticationError {
            SignInMetrics.attempt("password", error.metricOutcome, metrics)
            throw error
        }
    }

    private func authenticateUncounted(
        identifier rawIdentifier: String, password: String, clientAddress: String?
    ) async throws -> Principal {
        let identifier = Self.normalizedIdentifier(rawIdentifier)
        try await spendAttempt(identifier: identifier, clientAddress: clientAddress)

        let credential: StoredCredential?
        do {
            credential =
                identifier.isEmpty ? nil : try await store.credential(forIdentifier: identifier)
        } catch {
            logger.error("credential store failed", metadata: ["error": "\(error)"])
            throw PasswordAuthenticationError.unavailable
        }

        let normalized = Self.normalizedPassword(password)
        // The pre-0.33 form, when it differs: tried only if the NFC one fails.
        let legacy = Self.legacyNormalizedPassword(password)
        let legacyForm = legacy == normalized ? nil : legacy

        guard let credential, let stored = credential.passwordHash else {
            // Spend what a real verification would — including the legacy
            // retry, when this password would get one — then refuse. Two
            // verifications for a real account and one for a missing one
            // would say which accounts exist.
            if let dummy = dummyHash.value {
                _ = hasher.verify(normalized, against: dummy)
                if let legacyForm { _ = hasher.verify(legacyForm, against: dummy) }
            }
            throw PasswordAuthenticationError.invalidCredentials
        }
        var verifiedLegacyForm = false
        if !hasher.verify(normalized, against: stored) {
            guard let legacyForm, hasher.verify(legacyForm, against: stored) else {
                throw PasswordAuthenticationError.invalidCredentials
            }
            verifiedLegacyForm = true
        }
        guard !credential.isDisabled else {
            throw PasswordAuthenticationError.accountDisabled
        }

        // A legacy-form match is always rehashed: the stored hash is of a
        // form this version no longer produces.
        if verifiedLegacyForm || hasher.needsRehash(stored) {
            Counter(label: SignInMetrics.passwordRehashes, factory: metrics).increment()
            do {
                try await store.updatePasswordHash(
                    hasher.hash(normalized), forSubject: credential.subject)
            } catch {
                // The user did sign in; the upgrade is retried next time.
                logger.warning(
                    "password hash upgrade failed",
                    metadata: ["subject": "\(credential.subject)", "error": "\(error)"])
            }
        }

        return Principal(
            subject: credential.subject, issuer: issuer, roles: credential.roles,
            claims: credential.standardClaims)
    }

    /// Hashes a password the way ``authenticate(identifier:password:clientAddress:)``
    /// will later verify it — normalized first. Registration and password
    /// changes call this rather than the hasher directly, or a password with
    /// non-ASCII characters could be stored in a form sign-in never produces.
    public func hashNewPassword(_ password: String) throws -> String {
        try hasher.hash(Self.normalizedPassword(password))
    }

    private func spendAttempt(identifier: String, clientAddress: String?) async throws {
        do {
            if let clientAddress {
                let decision = try await limiter.consume(
                    "flight.sign-in.address:\(clientAddress)", quota: throttle.perAddress)
                guard decision.isAllowed else {
                    throw PasswordAuthenticationError.throttled(retryAfter: decision.retryAfter)
                }
            }
            // Case-folded for the budget whatever the store does with case,
            // so "Ada" and "ada" cannot each take ten guesses.
            let decision = try await limiter.consume(
                "flight.sign-in.identifier:\(identifier.lowercased())",
                quota: throttle.perIdentifier)
            guard decision.isAllowed else {
                throw PasswordAuthenticationError.throttled(retryAfter: decision.retryAfter)
            }
        } catch let error as PasswordAuthenticationError {
            throw error
        } catch {
            // Closed, not open: the throttle is the brute-force defence, and a
            // limiter outage is exactly when nothing else would notice a
            // flood. The general `RateLimiting` middleware fails open (D33);
            // sign-in is the one place that trade reverses (D39).
            logger.error("sign-in throttle unavailable", metadata: ["error": "\(error)"])
            throw PasswordAuthenticationError.unavailable
        }
    }

    static func normalizedIdentifier(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    /// NFC — SP 800-63B-4 §3.1.1.2.
    static func normalizedPassword(_ raw: String) -> String {
        raw.precomposedStringWithCanonicalMapping
    }

    /// NFKC — what 0.31 and 0.32 hashed. Only ever used to verify, never to
    /// hash.
    static func legacyNormalizedPassword(_ raw: String) -> String {
        raw.precomposedStringWithCompatibilityMapping
    }
}

/// A hash of nothing in particular, made once with the current parameters,
/// for the unknown-account path to verify against. Lazily, because hashing
/// at construction would put Argon2 work into composition.
private final class DummyHash: Sendable {
    private let hasher: any PasswordHashing
    private let cached = Mutex<String?>(nil)

    init(hasher: any PasswordHashing) { self.hasher = hasher }

    var value: String? {
        if let hash = cached.withLock({ $0 }) { return hash }
        guard let hash = try? hasher.hash("flight.dummy-password") else { return nil }
        cached.withLock { $0 = hash }
        return hash
    }
}

/// Why a password sign-in was refused. Every case renders generically; the
/// cause is for the log, not the caller.
public enum PasswordAuthenticationError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Unknown identifier, no password on the account, or the wrong password
    /// — deliberately indistinguishable.
    case invalidCredentials
    /// The password was right and the account is disabled. Reported only
    /// after the password verifies, so it tells an attacker nothing.
    case accountDisabled
    /// Too many attempts for this identifier or from this address.
    case throttled(retryAfter: Duration?)
    /// The credential store or the throttle could not answer. Sign-in fails
    /// closed.
    case unavailable

    public var description: String {
        switch self {
        case .invalidCredentials: "invalid credentials"
        case .accountDisabled: "account disabled"
        case .throttled(let retryAfter):
            "throttled; retry after \(retryAfter.map { "\($0)" } ?? "unknown")"
        case .unavailable: "credential store or sign-in throttle unavailable"
        }
    }
}

extension PasswordAuthenticationError: HTTPErrorRepresentable {
    public var httpStatus: HTTPResponse.Status {
        switch self {
        case .invalidCredentials: .unauthorized
        case .accountDisabled: .forbidden
        case .throttled: .tooManyRequests
        case .unavailable: .serviceUnavailable
        }
    }

    public var httpMessage: String {
        switch self {
        case .invalidCredentials: "Invalid credentials"
        case .accountDisabled: "Account disabled"
        case .throttled: "Too many sign-in attempts"
        case .unavailable: "Service Unavailable"
        }
    }

    public var httpHeaders: HTTPFields {
        guard case .throttled(let retryAfter?) = self else { return [:] }
        // Whole seconds, rounded up: an early retry is refused again.
        let seconds =
            retryAfter.components.seconds + (retryAfter.components.attoseconds > 0 ? 1 : 0)
        return [.retryAfter: String(max(seconds, 1))]
    }
}
