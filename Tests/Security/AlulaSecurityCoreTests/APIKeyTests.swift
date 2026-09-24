import Foundation
import Testing

@testable import AlulaSecurityCore

@Suite("API keys")
struct APIKeyTests {
    struct Fallback: TokenValidator {
        func validate(_ token: String) async throws -> Principal {
            Principal(subject: "from-oidc", issuer: "oidc")
        }
    }

    private func setUp(
        expiresAt: Date? = nil, fallback: (any TokenValidator)? = nil
    ) -> (APIKeys.Issued, InMemoryAPIKeyStore, APIKeyValidator) {
        let issued = APIKeys.issue(
            prefix: "sk", subject: "svc-billing", roles: ["service"], scopes: ["invoices:read"],
            expiresAt: expiresAt)
        let store = InMemoryAPIKeyStore()
        store.save(issued.stored)
        return (
            issued, store,
            APIKeyValidator(store: store, prefix: "sk", issuer: "app", fallback: fallback)
        )
    }

    @Test("an issued key authenticates as its subject, with its roles and scopes")
    func valid() async throws {
        let (issued, _, validator) = setUp()
        let principal = try await validator.validate(issued.key)
        #expect(principal.subject == "svc-billing")
        #expect(principal.roles == ["service"])
        #expect(principal.scopes == ["invoices:read"])
        #expect(principal.issuer == "app")
    }

    @Test("only a digest of the secret is stored")
    func digestOnly() {
        let issued = APIKeys.issue(prefix: "sk", subject: "s")
        let secret = String(issued.key.split(separator: "_", maxSplits: 2)[2])
        #expect(!issued.stored.secretDigest.contains(secret))
        #expect(issued.stored.secretDigest == APIKeys.digest(secret))
    }

    @Test("a wrong secret, an unknown id, a revoked or an expired key is refused")
    func refused() async throws {
        let (issued, store, validator) = setUp()
        let id = issued.stored.id
        await #expect(throws: TokenValidationError.self) {
            try await validator.validate("sk_\(id)_wrong-secret")
        }
        await #expect(throws: TokenValidationError.self) {
            try await validator.validate("sk_0000000000000000_\(String(repeating: "a", count: 43))")
        }
        var revoked = issued.stored
        revoked.revoked = true
        store.save(revoked)
        await #expect(throws: TokenValidationError.self) {
            try await validator.validate(issued.key)
        }

        let (expired, _, expiring) = setUp(expiresAt: Date(timeIntervalSinceNow: -1))
        await #expect(throws: TokenValidationError.self) {
            try await expiring.validate(expired.key)
        }
    }

    @Test("a token without the prefix goes to the fallback, or is refused without one")
    func fallback() async throws {
        let (_, _, withFallback) = setUp(fallback: Fallback())
        #expect(try await withFallback.validate("eyJhbGciOi.x.y").subject == "from-oidc")
        let (_, _, without) = setUp()
        await #expect(throws: TokenValidationError.self) {
            try await without.validate("eyJhbGciOi.x.y")
        }
    }

    @Test("malformed keys are refused before the store is asked")
    func malformed() {
        for bad in [
            "sk_", "sk_short_x", "sk_zzzzzzzzzzzzzzzz_secret", "sk_0123456789abcdef-secret",
        ] {
            #expect(APIKeys.parse(bad, prefix: "sk") == nil, "\(bad)")
        }
    }
}
