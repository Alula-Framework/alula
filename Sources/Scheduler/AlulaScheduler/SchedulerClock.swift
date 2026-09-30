import Foundation

/// The scheduler's view of time, injectable so tests do not sleep.
///
/// A scheduler tested against the real clock is a slow test suite and a
/// flaky one — the two properties worth having least. With this seam a test
/// can drive a year of firings in microseconds and assert the exact
/// sequence, which is the only way to check things like "a daily job fires
/// once on the day the clocks go back".
public protocol SchedulerClock: Sendable {
    /// The current instant, by this clock.
    var now: Date { get }
    /// Suspends until `instant`, or returns immediately if it has passed.
    /// Throws `CancellationError` when the task is cancelled.
    func sleep(until instant: Date) async throws
}

/// The real clock.
public struct SystemSchedulerClock: SchedulerClock {
    /// The system clock; the scheduler's default.
    public init() {}
    /// `Date()`.
    public var now: Date { Date() }

    /// `Task.sleep` for the remaining interval, sub-second parts included.
    public func sleep(until instant: Date) async throws {
        let interval = instant.timeIntervalSince(Date())
        guard interval > 0 else { return }
        try await Task.sleep(for: .seconds(interval))
    }
}
