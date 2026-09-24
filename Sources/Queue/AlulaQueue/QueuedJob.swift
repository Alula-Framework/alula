import Foundation

/// A unit of background work: the data a handler needs, and nothing else.
///
/// ```swift
/// struct SendWelcomeEmail: QueuedJob {
///     static let queue = "mail"
///     let userID: UUID
/// }
///
/// try await jobs.enqueue(SendWelcomeEmail(userID: user.id))
/// ```
///
/// A job is *data*, encoded as JSON when enqueued and decoded when run, so it
/// may be run by another process, after a deploy, days later. Keep it to the
/// identifiers the work needs rather than whole objects: the user may have
/// changed by the time it runs, and the handler should read them fresh.
///
/// Delivery is **at least once**. A worker that crashes mid-run leaves its
/// lease to expire, and the job runs again, so a handler must be safe to
/// repeat: check whether the email was sent before sending it.
public protocol QueuedJob: Codable, Sendable {
    /// What identifies this kind of job in storage. Defaults to the type's
    /// name; set it explicitly before renaming a type that has jobs in flight,
    /// or those jobs will find no handler.
    static var kind: String { get }

    /// Which queue it runs on. Queues have their own concurrency, so slow
    /// work (a report) cannot starve fast work (an email). Default `"default"`.
    static var queue: String { get }

    /// How many times it is tried and how long to wait between tries.
    static var retry: RetryPolicy { get }
}

extension QueuedJob {
    public static var kind: String { String(describing: Self.self) }
    public static var queue: String { "default" }
    public static var retry: RetryPolicy { .default }
}

/// How a failed job is retried.
///
/// The delay before attempt *n + 1* is `base × 2^(n−1)`, capped at `cap`,
/// with ±`jitter` so a batch that failed together does not retry together.
/// The defaults — 10 attempts, 15 seconds doubling to at most an hour —
/// span roughly three and a half hours, long enough to ride out a deploy or
/// a provider's bad afternoon.
public struct RetryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var base: Duration
    public var cap: Duration
    /// A fraction of the delay, `0...1`.
    public var jitter: Double

    public init(
        maxAttempts: Int = 10, base: Duration = .seconds(15), cap: Duration = .seconds(3600),
        jitter: Double = 0.1
    ) {
        precondition(maxAttempts >= 1, "a job has to be tried at least once")
        self.maxAttempts = maxAttempts
        self.base = base
        self.cap = cap
        self.jitter = min(max(jitter, 0), 1)
    }

    public static let `default` = RetryPolicy()

    /// Try once; a failure is final.
    public static let never = RetryPolicy(maxAttempts: 1)

    /// The delay after failed attempt `attempt` (1-based), before jitter is
    /// applied by `delay(after:using:)`.
    public func baseDelay(after attempt: Int) -> Duration {
        let exponent = min(max(attempt - 1, 0), 40)
        let seconds = min(base.queueSeconds * pow(2, Double(exponent)), cap.queueSeconds)
        return .milliseconds(Int64(seconds * 1000))
    }

    func delay(after attempt: Int, using random: inout some RandomNumberGenerator) -> Duration {
        let base = baseDelay(after: attempt).queueSeconds
        let spread = base * jitter
        let seconds = spread > 0 ? base + Double.random(in: -spread...spread, using: &random) : base
        return .milliseconds(Int64(max(seconds, 0) * 1000))
    }
}

/// Thrown from a handler to stop retrying: the job is discarded now, with this
/// reason recorded, however many attempts it had left. For failures a retry
/// cannot fix — the account it was about no longer exists.
public struct DiscardJob: Error, Sendable, CustomStringConvertible {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { reason }
}

extension Duration {
    var queueSeconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
