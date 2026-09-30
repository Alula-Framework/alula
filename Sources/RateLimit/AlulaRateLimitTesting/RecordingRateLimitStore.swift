import AlulaRateLimit
import Synchronization

/// A `RateLimitStore` that records every call and decides with the real
/// GCRA math over a clock the test moves, so a suite can assert both what
/// was limited and what the limiter concluded. The analogue of
/// `RecordingSessionStore` and `RecordingCache`.
///
/// ```swift
/// let limits = RecordingRateLimitStore()
/// let client = try TestClient(
///     routes: …,
///     middleware: MiddlewareRegistration.lane(.default, [
///         RateLimiting(store: limits, quota: .perMinute(2)) { $0.request.path }
///     ]))
///
/// _ = await client.get("/search")
/// _ = await client.get("/search")
/// #expect(await client.get("/search").status == .tooManyRequests)
/// #expect(limits.consumed.map(\.key) == ["/search", "/search", "/search"])
///
/// limits.advance(by: .seconds(60))
/// #expect(await client.get("/search").status == .ok)
/// ```
///
/// `misbehave()` makes every call throw, which is a store outage, and the
/// path the middleware's fail-open policy exists for.
public final class RecordingRateLimitStore: RateLimitStore, Sendable {
    /// One recorded call: what was asked, and what was decided.
    public struct Call: Sendable, Equatable {
        /// The key limited.
        public let key: String
        /// Permits asked for.
        public let cost: Int
        /// The quota the key was held to.
        public let quota: RateLimitQuota
        /// Whether the call was admitted.
        public let isAllowed: Bool
    }

    private struct State {
        var calls: [Call] = []
        var misbehaving = false
    }

    /// A reference box, because `Mutex` is noncopyable and the backing store
    /// captures this in an escaping closure.
    private final class Clock: Sendable {
        private let microseconds: Mutex<Int64>

        init(_ microseconds: Int64) {
            self.microseconds = Mutex(microseconds)
        }

        var now: Int64 { microseconds.withLock { $0 } }

        func advance(by delta: Int64) {
            microseconds.withLock { $0 += delta }
        }
    }

    private let state = Mutex(State())
    private let clock: Clock
    private let backing: InMemoryRateLimitStore

    /// A store over an `InMemoryRateLimitStore` whose clock starts at
    /// `microseconds` and moves only with ``advance(by:)``.
    public init(startingAt microseconds: Int64 = 0) {
        // A real store and the real algorithm, with only time faked. The
        // alternative is a stub that agrees with the production limiter
        // until the day it does not.
        let clock = Clock(microseconds)
        self.clock = clock
        self.backing = InMemoryRateLimitStore(now: { clock.now })
    }

    /// Throws `RateLimitStoreError` while misbehaving, recording nothing;
    /// otherwise decides as the in-memory store does and records the call.
    /// A negative `cost` throws and is not recorded.
    public func consume(key: String, cost: Int, quota: RateLimitQuota) async throws
        -> RateLimitDecision
    {
        try state.withLock { state in
            guard !state.misbehaving else {
                throw RateLimitStoreError(reason: "store is misbehaving")
            }
        }
        let decision = try await backing.consume(key: key, cost: cost, quota: quota)
        state.withLock {
            $0.calls.append(
                Call(key: key, cost: cost, quota: quota, isAllowed: decision.isAllowed))
        }
        return decision
    }

    // MARK: - Driving it

    /// Moves the clock the backing store reads, so quotas replenish without
    /// the suite sleeping.
    public func advance(by duration: Duration) {
        clock.advance(by: duration.recordingMicroseconds)
    }

    /// From now on, every call throws `RateLimitStoreError`. A call that
    /// throws is not recorded in ``consumed`` and spends nothing.
    public func misbehave() {
        state.withLock { $0.misbehaving = true }
    }

    /// Stops misbehaving, for testing recovery. The limiter state is as it
    /// was before ``misbehave()``: calls refused during the outage spent
    /// nothing, so a key's allowance has only been refilling since.
    public func recover() {
        state.withLock { $0.misbehaving = false }
    }

    // MARK: - Inspection

    /// Every call, in order, with what it decided.
    public var consumed: [Call] {
        state.withLock { $0.calls }
    }

    /// Calls that were refused.
    public var denied: [Call] {
        state.withLock { $0.calls.filter { !$0.isAllowed } }
    }

    /// How many calls named `key`.
    public func callCount(for key: String) -> Int {
        state.withLock { $0.calls.filter { $0.key == key }.count }
    }
}

extension Duration {
    fileprivate var recordingMicroseconds: Int64 {
        let parts = components
        return parts.seconds * 1_000_000 + Int64(parts.attoseconds / 1_000_000_000_000)
    }
}
