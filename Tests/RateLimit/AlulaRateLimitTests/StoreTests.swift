import AlulaCore
import AlulaRateLimitTesting
import Synchronization
import Testing

@testable import AlulaRateLimit

/// A clock the test moves, in the microseconds the stores read.
private final class TestClock: Sendable {
    private let microseconds = Mutex<Int64>(0)

    var now: @Sendable () -> Int64 {
        { self.microseconds.withLock { $0 } }
    }

    func advance(by duration: Duration) {
        microseconds.withLock { $0 += duration.rateLimitMicroseconds }
    }
}

@Suite("InMemoryRateLimitStore")
struct InMemoryRateLimitStoreTests {
    private let clock = TestClock()
    private let quota = RateLimitQuota.perSecond(3)

    private func store(maxEntries: Int = 100) -> InMemoryRateLimitStore {
        InMemoryRateLimitStore(maxEntries: maxEntries, now: clock.now)
    }

    @Test("a key spends its burst, is refused, and recovers on the clock")
    func spendAndRecover() async throws {
        let store = store()
        for _ in 0..<3 {
            #expect(try await store.consume(key: "a", quota: quota).isAllowed)
        }
        let denied = try await store.consume(key: "a", quota: quota)
        #expect(!denied.isAllowed)
        #expect(denied.remaining == 0)
        #expect(denied.retryAfter != nil)

        clock.advance(by: .milliseconds(334))
        #expect(try await store.consume(key: "a", quota: quota).isAllowed)
    }

    @Test("keys are independent")
    func keysAreIndependent() async throws {
        let store = store()
        for _ in 0..<3 {
            #expect(try await store.consume(key: "a", quota: quota).isAllowed)
        }
        #expect(!(try await store.consume(key: "a", quota: quota).isAllowed))
        #expect(try await store.consume(key: "b", quota: quota).isAllowed, "b has its own budget")
    }

    @Test("one store serves different quotas, because the quota is per call")
    func quotaIsPerCall() async throws {
        let store = store()
        #expect(try await store.consume(key: "login", quota: .perMinute(1)).isAllowed)
        #expect(!(try await store.consume(key: "login", quota: .perMinute(1)).isAllowed))
        // A different key under a roomier quota is unaffected: nothing about
        // the store is configured for one limit.
        #expect(try await store.consume(key: "read", quota: .perSecond(100)).isAllowed)
    }

    @Test("a refused call is not recorded, so the key is not pushed further out")
    func denialDoesNotConsume() async throws {
        let store = store()
        for _ in 0..<3 { _ = try await store.consume(key: "a", quota: quota) }
        for _ in 0..<20 { _ = try await store.consume(key: "a", quota: quota) }
        clock.advance(by: .milliseconds(334))
        #expect(try await store.consume(key: "a", quota: quota).isAllowed)
    }

    @Test("expired keys are swept before live ones when the bound is reached")
    func boundSweepsExpiredFirst() async throws {
        let store = store(maxEntries: 4)
        for key in ["a", "b", "c"] {
            _ = try await store.consume(key: key, cost: 3, quota: quota)
        }
        // Those three are spent, so a second later they are back at full and
        // carry no information worth keeping.
        clock.advance(by: .seconds(2))
        _ = try await store.consume(key: "live", cost: 3, quota: quota)
        _ = try await store.consume(key: "fifth", cost: 3, quota: quota)
        #expect(store.count == 2, "the three expired keys went, the two live ones stayed")
        #expect(!(try await store.consume(key: "live", quota: quota).isAllowed))
    }

    @Test("past the bound with nothing expired, the keys closest to expiry go")
    func boundEvictsNearestExpiry() async throws {
        let store = store(maxEntries: 4)
        // Spend one permit on each, a moment apart, so their arrival times
        // differ: the earliest is the closest to being back at full.
        for key in ["a", "b", "c", "d"] {
            _ = try await store.consume(key: key, quota: .perMinute(60))
            clock.advance(by: .milliseconds(10))
        }
        _ = try await store.consume(key: "e", quota: .perMinute(60))
        #expect(store.count <= 4)
        // Dropping a key restores its allowance, which is the honest
        // direction for a bound to fail in: too permissive, never punitive.
        #expect(try await store.consume(key: "a", quota: .perMinute(60)).isAllowed)
    }

    @Test("a zero cost probes without spending")
    func probe() async throws {
        let store = store()
        _ = try await store.consume(key: "a", quota: quota)
        let probe = try await store.consume(key: "a", cost: 0, quota: quota)
        #expect(probe.isAllowed)
        #expect(probe.remaining == 2)
        let again = try await store.consume(key: "a", cost: 0, quota: quota)
        #expect(again.remaining == 2, "probing twice changes nothing")
    }

    @Test("a cost over the burst is unsatisfiable rather than deferred")
    func unsatisfiable() async throws {
        let decision = try await store().consume(key: "a", cost: 99, quota: quota)
        #expect(!decision.isAllowed)
        #expect(decision.isUnsatisfiable)
        #expect(decision.retryAfter == nil)
    }
}

@Suite("RecordingRateLimitStore")
struct RecordingRateLimitStoreTests {

    @Test("it records every call with what was decided, and moves on its own clock")
    func records() async throws {
        let store = RecordingRateLimitStore()
        let quota = RateLimitQuota.perMinute(2)
        #expect(try await store.consume(key: "a", quota: quota).isAllowed)
        #expect(try await store.consume(key: "a", quota: quota).isAllowed)
        #expect(!(try await store.consume(key: "a", quota: quota).isAllowed))

        #expect(store.consumed.count == 3)
        #expect(store.consumed.map(\.key) == ["a", "a", "a"])
        #expect(store.denied.count == 1)
        #expect(store.callCount(for: "a") == 3)

        store.advance(by: .seconds(60))
        #expect(try await store.consume(key: "a", quota: quota).isAllowed, "the quota replenished")
    }

    @Test("misbehaving throws until it recovers")
    func misbehave() async throws {
        let store = RecordingRateLimitStore()
        store.misbehave()
        await #expect(throws: RateLimitStoreError.self) {
            try await store.consume(key: "a", quota: .perMinute(1))
        }
        store.recover()
        #expect(try await store.consume(key: "a", quota: .perMinute(1)).isAllowed)
    }
}

@Suite("RateLimitQuota and the module")
struct QuotaAndModuleTests {

    @Test("the factories describe the rate they name")
    func factories() {
        #expect(RateLimitQuota.perSecond(10).period == .seconds(1))
        #expect(RateLimitQuota.perMinute(10).period == .seconds(60))
        #expect(RateLimitQuota.perHour(10).period == .seconds(3600))
        #expect(RateLimitQuota.perDay(10).period == .seconds(86_400))
        #expect(RateLimitQuota.perMinute(10).burst == 10, "the whole quota, by default")
        #expect(RateLimitQuota.perMinute(10, burst: 2).burst == 2)
        #expect(RateLimitQuota.perSecond(10).emissionIntervalMicroseconds == 100_000)
        #expect(RateLimitQuota.perSecond(10).burstOffsetMicroseconds == 1_000_000)
    }

    @Test("with no adapter the store is in-memory, bounded by configuration")
    func defaults() throws {
        let module = try AlulaRateLimitModule(configuration: Configuration())
        #expect(module.limiter.store is InMemoryRateLimitStore)

        let bounded = try AlulaRateLimitModule(
            configuration: Configuration(values: ["rate-limit.memory.max-entries": "7"]))
        #expect((bounded.limiter.store as? InMemoryRateLimitStore)?.maxEntries == 7)
    }

    @Test("an adapter's store wins over the in-memory default")
    func adapter() throws {
        let module = try AlulaRateLimitModule(
            configuration: Configuration(), store: RecordingRateLimitStore())
        #expect(module.limiter.store is RecordingRateLimitStore)
    }

    @Test("configuring the Valkey URL without listing its module fails composition, naming it")
    func unloadedAdapter() throws {
        let configuration = Configuration(values: ["rate-limit.valkey.url": "valkey://localhost"])
        #expect(throws: UnloadedAdapterError.self) {
            try AlulaRateLimitModule(configuration: configuration)
        }
        do {
            _ = try AlulaRateLimitModule(configuration: configuration)
        } catch let error as UnloadedAdapterError {
            #expect(error.module == "AlulaRateLimitValkeyModule")
            #expect(error.configurationKey == "rate-limit.valkey.url")
        }
    }

    @Test("a bound that is not positive is refused")
    func badBound() throws {
        #expect(throws: RateLimitConfigurationError.invalidMaxEntries(0)) {
            try AlulaRateLimitModule(
                configuration: Configuration(values: ["rate-limit.memory.max-entries": "0"]))
        }
    }

    @Test("the limiter facade forwards to its store")
    func limiterFacade() async throws {
        let store = RecordingRateLimitStore()
        let limiter = RateLimiter(store: store)
        _ = try await limiter.consume("a", cost: 2, quota: .perMinute(5))
        #expect(store.consumed.first?.cost == 2)
    }
}
