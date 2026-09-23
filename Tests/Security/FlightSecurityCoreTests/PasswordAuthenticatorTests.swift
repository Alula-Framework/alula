import FlightRateLimit
import FlightRateLimitTesting
import FlightWeb
import Foundation
import HTTPTypes
import Testing

@testable import FlightSecurityCore

/// A hasher that counts verifications, so a test can see that the
/// unknown-account path did the same work as a real one.
private final class CountingHasher: PasswordHashing, @unchecked Sendable {
    let inner: Argon2idHashing
    private let lock = NSLock()
    private var _verifications = 0
    var verifications: Int { lock.withLock { _verifications } }

    init(_ inner: Argon2idHashing) { self.inner = inner }
    func hash(_ password: String) throws -> String { try inner.hash(password) }
    func verify(_ password: String, against hash: String) -> Bool {
        lock.withLock { _verifications += 1 }
        return inner.verify(password, against: hash)
    }
    func needsRehash(_ hash: String) -> Bool { inner.needsRehash(hash) }
}

/// A store that is down.
private struct FailingStore: CredentialStore {
    struct Down: Error {}
    func credential(forIdentifier identifier: String) async throws -> StoredCredential? {
        throw Down()
    }
    func updatePasswordHash(_ hash: String, forSubject subject: String) async throws {
        throw Down()
    }
}

/// A limiter store that is down.
private struct FailingLimiterStore: RateLimitStore {
    struct Down: Error {}
    func consume(key: String, cost: Int, quota: RateLimitQuota) async throws -> RateLimitDecision {
        throw Down()
    }
}

@Suite("PasswordAuthenticator")
struct PasswordAuthenticatorTests {
    private static let fastParameters = Argon2idHashing.Parameters(
        timeCost: 1, memoryCost: 8, parallelism: 1)
    private let fast = Argon2idHashing(parameters: fastParameters)
    private let store = InMemoryCredentialStore()
    private let limits = RecordingRateLimitStore()

    private func authenticator(
        hasher: (any PasswordHashing)? = nil,
        store: (any CredentialStore)? = nil,
        limiterStore: (any RateLimitStore)? = nil,
        throttle: PasswordAuthenticator.Throttle = .default
    ) -> PasswordAuthenticator {
        PasswordAuthenticator(
            store: store ?? self.store, issuer: "https://app.example.com",
            hasher: hasher ?? fast, limiter: RateLimiter(store: limiterStore ?? limits),
            throttle: throttle)
    }

    private func addAda(password: String = "correct horse", disabled: Bool = false) throws {
        store.insert(
            StoredCredential(
                subject: "user-1", passwordHash: try fast.hash(password), roles: ["author"],
                isDisabled: disabled, email: "ada@example.com", emailVerified: true,
                name: "Ada Lovelace", preferredUsername: "ada"),
            identifiers: ["ada@example.com", "ada"])
    }

    // MARK: The happy path

    @Test("the right password yields a principal with the standard claims")
    func signsIn() async throws {
        try addAda()
        let principal = try await authenticator().authenticate(
            identifier: "ada@example.com", password: "correct horse", clientAddress: "198.51.100.7")
        #expect(principal.subject == "user-1")
        #expect(principal.issuer == "https://app.example.com")
        #expect(principal.roles == ["author"])
        #expect(principal.email == "ada@example.com")
        #expect(principal.emailVerified)
        #expect(principal.name == "Ada Lovelace")
        #expect(principal.preferredUsername == "ada")
    }

    @Test("any identifier the store maps to the account works; whitespace is trimmed")
    func identifiers() async throws {
        try addAda()
        let auth = authenticator()
        #expect(
            try await auth.authenticate(
                identifier: "ada", password: "correct horse", clientAddress: nil
            ).subject == "user-1")
        #expect(
            try await auth.authenticate(
                identifier: "  ADA@example.com \n", password: "correct horse", clientAddress: nil
            ).subject == "user-1")
    }

    // MARK: One answer for every wrong guess

    @Test("wrong password, unknown account, and no password are indistinguishable")
    func oneAnswer() async throws {
        try addAda()
        store.insert(
            StoredCredential(subject: "invited", passwordHash: nil), identifiers: ["invited"])
        let auth = authenticator()
        for (identifier, password) in [
            ("ada", "wrong"), ("nobody", "anything"), ("invited", ""), ("", "x"),
        ] {
            await #expect(throws: PasswordAuthenticationError.invalidCredentials) {
                try await auth.authenticate(
                    identifier: identifier, password: password, clientAddress: nil)
            }
        }
    }

    @Test("an unknown account costs a verification, the same as a known one")
    func unknownAccountDoesTheWork() async throws {
        let counting = CountingHasher(fast)
        let auth = authenticator(hasher: counting)
        _ = try? await auth.authenticate(
            identifier: "nobody", password: "guess", clientAddress: nil)
        #expect(counting.verifications == 1)
    }

    @Test("a disabled account is reported only once its password verifies")
    func disabled() async throws {
        try addAda(disabled: true)
        let auth = authenticator()
        await #expect(throws: PasswordAuthenticationError.invalidCredentials) {
            try await auth.authenticate(identifier: "ada", password: "wrong", clientAddress: nil)
        }
        await #expect(throws: PasswordAuthenticationError.accountDisabled) {
            try await auth.authenticate(
                identifier: "ada", password: "correct horse", clientAddress: nil)
        }
    }

    // MARK: Normalization

    @Test("a password typed composed or decomposed verifies the same")
    func passwordNormalization() async throws {
        let auth = authenticator()
        let composed = "caf\u{00E9} au lait"
        let decomposed = "cafe\u{0301} au lait"
        store.insert(
            StoredCredential(subject: "u", passwordHash: try auth.hashNewPassword(composed)),
            identifiers: ["u"])
        #expect(
            try await auth.authenticate(identifier: "u", password: decomposed, clientAddress: nil)
                .subject == "u")
    }

    @Test("an ASCII hash made before normalization existed still verifies")
    func asciiUnaffected() async throws {
        try addAda()  // hashed with the raw hasher, no normalization
        #expect(
            try await authenticator().authenticate(
                identifier: "ada", password: "correct horse", clientAddress: nil
            ).subject == "user-1")
    }

    // MARK: Throttling

    @Test("attempts past the per-identifier budget are refused before any hashing")
    func perIdentifierThrottle() async throws {
        try addAda()
        let counting = CountingHasher(fast)
        let auth = authenticator(
            hasher: counting,
            throttle: .init(perIdentifier: .perMinute(3), perAddress: .perMinute(100)))
        for _ in 0..<3 {
            _ = try? await auth.authenticate(
                identifier: "ada", password: "wrong", clientAddress: "198.51.100.7")
        }
        let before = counting.verifications
        await #expect(throws: PasswordAuthenticationError.self) {
            try await auth.authenticate(
                identifier: "ADA", password: "correct horse", clientAddress: "203.0.113.9")
        }
        #expect(counting.verifications == before, "a refused attempt costs no hash")
        #expect(
            limits.denied.last?.key == "flight.sign-in.identifier:ada", "case-folded for the budget"
        )
    }

    @Test("attempts past the per-address budget are refused across identifiers")
    func perAddressThrottle() async throws {
        let auth = authenticator(
            throttle: .init(perIdentifier: .perMinute(100), perAddress: .perMinute(2)))
        for name in ["a", "b"] {
            _ = try? await auth.authenticate(
                identifier: name, password: "x", clientAddress: "198.51.100.7")
        }
        do {
            _ = try await auth.authenticate(
                identifier: "c", password: "x", clientAddress: "198.51.100.7")
            Issue.record("expected a throttle")
        } catch PasswordAuthenticationError.throttled(let retryAfter) {
            #expect(retryAfter != nil)
        }
        // A different address is unaffected.
        await #expect(throws: PasswordAuthenticationError.invalidCredentials) {
            try await auth.authenticate(
                identifier: "c", password: "x", clientAddress: "203.0.113.9")
        }
    }

    @Test("a throttled refusal renders as a 429 with Retry-After in whole seconds, rounded up")
    func throttledRendering() {
        let error = PasswordAuthenticationError.throttled(retryAfter: .milliseconds(1500))
        #expect(error.httpStatus == .tooManyRequests)
        #expect(error.httpHeaders[.retryAfter] == "2")
    }

    // MARK: Failing closed

    @Test("a limiter that is down fails sign-in closed, as 503")
    func limiterDown() async throws {
        try addAda()
        await #expect(throws: PasswordAuthenticationError.unavailable) {
            try await authenticator(limiterStore: FailingLimiterStore())
                .authenticate(identifier: "ada", password: "correct horse", clientAddress: nil)
        }
        #expect(PasswordAuthenticationError.unavailable.httpStatus == .serviceUnavailable)
    }

    @Test("a credential store that is down is a 503, not a wrong password")
    func storeDown() async throws {
        await #expect(throws: PasswordAuthenticationError.unavailable) {
            try await authenticator(store: FailingStore())
                .authenticate(identifier: "ada", password: "x", clientAddress: nil)
        }
    }

    // MARK: Rehashing

    @Test("a hash made with weaker parameters is replaced at sign-in")
    func rehash() async throws {
        let weaker = Argon2idHashing(parameters: .init(timeCost: 1, memoryCost: 8, parallelism: 1))
        let stronger = Argon2idHashing(
            parameters: .init(timeCost: 2, memoryCost: 16, parallelism: 1))
        store.insert(
            StoredCredential(subject: "u", passwordHash: try weaker.hash("pw")), identifiers: ["u"])
        _ = try await authenticator(hasher: stronger).authenticate(
            identifier: "u", password: "pw", clientAddress: nil)
        let upgraded = try #require(store.credential(forSubject: "u")?.passwordHash)
        #expect(!stronger.needsRehash(upgraded))
        #expect(stronger.verify("pw", against: upgraded))
    }

    // MARK: Wire hygiene

    @Test("every refusal's wire message is generic")
    func wireMessages() {
        #expect(PasswordAuthenticationError.invalidCredentials.httpMessage == "Invalid credentials")
        #expect(PasswordAuthenticationError.invalidCredentials.httpStatus == .unauthorized)
        #expect(PasswordAuthenticationError.accountDisabled.httpStatus == .forbidden)
    }

    // MARK: NFC, and the NFKC hashes 0.31/0.32 made

    @Test(
        "a password with compatibility characters hashed under the old NFKC form still signs in, and is rehashed under NFC"
    )
    func legacyNFKCUpgrades() async throws {
        let password = "\u{FB01}sh and chips"  // "ﬁ": NFKC folds it to "fi"; NFC keeps it
        #expect(
            PasswordAuthenticator.normalizedPassword(password)
                != PasswordAuthenticator.legacyNormalizedPassword(password))
        // What 0.32 stored: the hash of the NFKC form.
        let legacyHash = try fast.hash(PasswordAuthenticator.legacyNormalizedPassword(password))
        store.insert(StoredCredential(subject: "u", passwordHash: legacyHash), identifiers: ["u"])

        #expect(
            try await authenticator().authenticate(
                identifier: "u", password: password, clientAddress: nil
            ).subject == "u")
        let upgraded = try #require(store.credential(forSubject: "u")?.passwordHash)
        #expect(upgraded != legacyHash, "rehashed on the spot")
        #expect(fast.verify(PasswordAuthenticator.normalizedPassword(password), against: upgraded))
        // And it keeps working from the new hash.
        #expect(
            try await authenticator().authenticate(
                identifier: "u", password: password, clientAddress: nil
            ).subject == "u")
    }

    @Test("under NFC a ligature and its letters are different passwords")
    func nfcKeepsCompatibilityCharactersDistinct() async throws {
        let auth = authenticator()
        store.insert(
            StoredCredential(subject: "u", passwordHash: try auth.hashNewPassword("\u{FB01}sh")),
            identifiers: ["u"])
        await #expect(throws: PasswordAuthenticationError.invalidCredentials) {
            try await auth.authenticate(identifier: "u", password: "fish", clientAddress: nil)
        }
    }

    @Test("an unknown account costs the legacy retry too, when the password would get one")
    func unknownAccountMatchesLegacyWork() async throws {
        let counting = CountingHasher(fast)
        let auth = authenticator(hasher: counting)
        _ = try? await auth.authenticate(
            identifier: "nobody", password: "\u{FB01}sh", clientAddress: nil)
        #expect(
            counting.verifications == 2,
            "the same two verifications a real account's wrong guess costs")
        _ = try? await auth.authenticate(
            identifier: "nobody", password: "plain ascii", clientAddress: nil)
        #expect(counting.verifications == 3, "and only one when the forms agree")
    }
}
