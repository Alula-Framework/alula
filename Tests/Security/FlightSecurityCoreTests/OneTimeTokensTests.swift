import FlightSessions
import Foundation
import Synchronization
import Testing

@testable import FlightSecurityCore

/// A store that remembers every key and value it was given, to show what a
/// leaked store would hold.
private final class ExposedStore: OneTimeTokenStore, Sendable {
    let inner = InMemoryOneTimeTokenStore()
    let written = Mutex<[(String, Data)]>([])
    func put(_ key: String, _ record: Data, ttl: Duration) async throws {
        written.withLock { $0.append((key, record)) }
        try await inner.put(key, record, ttl: ttl)
    }
    func take(_ key: String) async throws -> Data? { try await inner.take(key) }
}

@Suite("OneTimeTokens")
struct OneTimeTokensTests {
    private let clock = TestClock()
    private var store: InMemoryOneTimeTokenStore {
        InMemoryOneTimeTokenStore(now: clock.nowProvider)
    }

    private func tokens(_ store: any OneTimeTokenStore) -> OneTimeTokens {
        OneTimeTokens(store: store, now: clock.nowProvider)
    }

    @Test("a token redeems once, for the subject it was issued to")
    func redeemsOnce() async throws {
        let tokens = tokens(store)
        let token = try await tokens.issue(
            for: "user-1", purpose: .passwordReset, lifetime: .seconds(3600))
        #expect(token.count == 43)
        #expect(try await tokens.redeem(token, purpose: .passwordReset) == "user-1")
        await #expect(throws: OneTimeTokenError.invalidOrExpired) {
            try await tokens.redeem(token, purpose: .passwordReset)
        }
    }

    @Test("the store never holds the token itself — only digests")
    func storeHoldsDigests() async throws {
        let exposed = ExposedStore()
        let token = try await tokens(exposed).issue(
            for: "user-1", purpose: .passwordReset, lifetime: .seconds(60), binding: "hash-v1")
        let (key, value) = try #require(exposed.written.withLock { $0.first })
        #expect(!key.contains(token))
        let stored = String(decoding: value, as: UTF8.self)
        #expect(!stored.contains(token))
        #expect(!stored.contains("hash-v1"), "the binding is a digest too")
    }

    @Test("a token for one purpose is refused for another, and is spent by trying")
    func purposeBound() async throws {
        let tokens = tokens(store)
        let token = try await tokens.issue(
            for: "user-1", purpose: .emailVerification, lifetime: .seconds(60))
        await #expect(throws: OneTimeTokenError.invalidOrExpired) {
            try await tokens.redeem(token, purpose: .passwordReset)
        }
        await #expect(throws: OneTimeTokenError.invalidOrExpired) {
            try await tokens.redeem(token, purpose: .emailVerification)
        }
    }

    @Test("an expired token is refused")
    func expires() async throws {
        let tokens = tokens(store)
        let token = try await tokens.issue(
            for: "user-1", purpose: .magicLink, lifetime: .seconds(60))
        clock.advance(by: 61)
        await #expect(throws: OneTimeTokenError.invalidOrExpired) {
            try await tokens.redeem(token, purpose: .magicLink)
        }
    }

    @Test("a binding that has changed voids the token — a changed password voids reset links")
    func binding() async throws {
        let tokens = tokens(store)
        let current = Mutex("hash-v1")
        let first = try await tokens.issue(
            for: "user-1", purpose: .passwordReset, lifetime: .seconds(60), binding: "hash-v1")
        let second = try await tokens.issue(
            for: "user-1", purpose: .passwordReset, lifetime: .seconds(60), binding: "hash-v1")

        #expect(
            try await tokens.redeem(first, purpose: .passwordReset) { _ in current.withLock { $0 } }
                == "user-1")
        current.withLock { $0 = "hash-v2" }  // the reset changed the password
        await #expect(throws: OneTimeTokenError.invalidOrExpired) {
            try await tokens.redeem(second, purpose: .passwordReset) { _ in current.withLock { $0 }
            }
        }
    }

    @Test("a bound token with no way to check the binding, or a vanished account, is refused")
    func bindingUncheckable() async throws {
        let tokens = tokens(store)
        let a = try await tokens.issue(
            for: "u", purpose: .passwordReset, lifetime: .seconds(60), binding: "h")
        await #expect(throws: OneTimeTokenError.invalidOrExpired) {
            try await tokens.redeem(a, purpose: .passwordReset)
        }
        let b = try await tokens.issue(
            for: "u", purpose: .passwordReset, lifetime: .seconds(60), binding: "h")
        await #expect(throws: OneTimeTokenError.invalidOrExpired) {
            try await tokens.redeem(b, purpose: .passwordReset) { _ in nil }
        }
    }

    @Test("twenty requests racing with one link get exactly one success")
    func racingRedemptions() async throws {
        let tokens = tokens(store)
        let token = try await tokens.issue(
            for: "user-1", purpose: .magicLink, lifetime: .seconds(60))
        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 {
                group.addTask { (try? await tokens.redeem(token, purpose: .magicLink)) != nil }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(successes == 1)
    }

    @Test("garbage and unknown tokens are refused without error detail")
    func garbage() async throws {
        let tokens = tokens(store)
        for token in ["", "nope", String(repeating: "a", count: 500)] {
            await #expect(throws: OneTimeTokenError.invalidOrExpired) {
                try await tokens.redeem(token, purpose: .passwordReset)
            }
        }
        #expect(OneTimeTokenError.invalidOrExpired.httpStatus == .badRequest)
    }

    @Test("the in-memory store is bounded, dropping the soonest to expire")
    func storeBound() async throws {
        let store = InMemoryOneTimeTokenStore(maxEntries: 2, now: clock.nowProvider)
        try await store.put("short", Data("1".utf8), ttl: .seconds(10))
        try await store.put("long", Data("2".utf8), ttl: .seconds(100))
        try await store.put("longer", Data("3".utf8), ttl: .seconds(200))
        #expect(store.count == 2)
        #expect(try await store.take("short") == nil)
        #expect(try await store.take("long") != nil)
    }
}
