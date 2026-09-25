import AlulaCore
import AlulaWeb
import AlulaWebTesting
import Foundation
import HTTPTypes
import Testing

@testable import AlulaSecurityCore

@Suite("Token strategies compose")
struct TokenStrategyTests {
    /// Stands in for OIDC: accepts anything it is given.
    struct People: TokenValidator {
        func validate(_ token: String) async throws -> Principal {
            Principal(subject: "person", issuer: "oidc")
        }
    }

    struct Named: TokenValidator {
        let subject: String
        func validate(_ token: String) async throws -> Principal {
            Principal(subject: subject, issuer: "test")
        }
    }

    @Test("a recognized token goes to its strategy; anything else to the fallback")
    func routing() async throws {
        let store = InMemoryAPIKeyStore()
        let issued = APIKeys.issue(prefix: "sk", subject: "svc-billing")
        store.save(issued.stored)
        let keys = APIKeyValidator(store: store, prefix: "sk", issuer: "app")
        let composite = CompositeTokenValidator(strategies: [keys.strategy], fallback: People())
        #expect(try await composite.validate(issued.key).subject == "svc-billing")
        #expect(try await composite.validate("eyJhbGciOi.x.y").subject == "person")
        // An API-key-shaped token that is wrong is refused by the key
        // strategy, never handed on to the fallback to try its luck.
        await #expect(throws: TokenValidationError.self) {
            try await composite.validate("sk_0000000000000000_nope")
        }
    }

    @Test("a token two strategies recognize is refused, whatever the order")
    func ambiguity() async throws {
        let a = TokenStrategy(
            "a", recognizes: { $0.hasPrefix("x") }, validator: Named(subject: "a"))
        let b = TokenStrategy(
            "b", recognizes: { $0.hasPrefix("xy") }, validator: Named(subject: "b"))
        for order in [[a, b], [b, a]] {
            let composite = CompositeTokenValidator(strategies: order, fallback: nil)
            await #expect(throws: TokenValidationError.self) { try await composite.validate("xyz") }
            #expect(try await composite.validate("xa").subject == "a")
        }
    }

    @Test("no strategy and no fallback: refused")
    func unrecognized() async throws {
        let composite = CompositeTokenValidator(strategies: [], fallback: nil)
        await #expect(throws: TokenValidationError.self) { try await composite.validate("t") }
    }

    @Test("the security module authenticates through contributed strategies and its validator")
    func throughTheModule() async throws {
        let store = InMemoryAPIKeyStore()
        let issued = APIKeys.issue(prefix: "sk", subject: "svc-billing")
        store.save(issued.stored)
        let keys = try AlulaAPIKeyModule(configuration: Configuration(), store: store)
        let security = AlulaSecurityModule(
            validator: People(), tokenStrategies: keys.tokenStrategies)
        let route = RouteRegistration(
            method: .get, path: "/me", source: "t", pipelines: [.authenticated]
        ) { context in .text(try context.requirePrincipal().subject) }
        let client = try TestClient(routes: [route], middleware: security.middleware)

        let key = await client.get("/me", headers: [.authorization: "Bearer \(issued.key)"])
        #expect(key.bodyText == "svc-billing")
        let person = await client.get("/me", headers: [.authorization: "Bearer eyJ.a.b"])
        #expect(person.bodyText == "person")
        let wrongKey = await client.get(
            "/me", headers: [.authorization: "Bearer sk_0000000000000000_x"])
        #expect(wrongKey.status == .unauthorized)
    }

    @Test("a malformed prefix in configuration fails composition")
    func badPrefix() {
        #expect(throws: (any Error).self) {
            try AlulaAPIKeyModule(
                configuration: Configuration(values: ["security.api-keys.prefix": "sk-live"]),
                store: InMemoryAPIKeyStore())
        }
    }
}
