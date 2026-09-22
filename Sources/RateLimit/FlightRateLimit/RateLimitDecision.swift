/// What a store decided about one call, and everything a caller needs to
/// answer the client with.
///
/// Every field is present on both outcomes, because a caller that allows a
/// request still wants to tell the client how much is left. That is what the
/// `X-RateLimit-*` headers carry, and it is the difference between a client
/// that can pace itself and one that discovers the limit by hitting it.
public struct RateLimitDecision: Sendable, Equatable {
    /// Whether the call may proceed.
    public let isAllowed: Bool

    /// Permits left after this call. Zero on a denial, and zero on the call
    /// that spends the last one.
    public let remaining: Int

    /// How long until this call would be admitted, on a denial.
    ///
    /// `nil` when ``isAllowed``, and also `nil` on a denial that no amount of
    /// waiting fixes: a `cost` larger than the quota's burst can never be
    /// admitted, and saying "retry in 200ms" to a caller who will be refused
    /// again forever is worse than saying nothing. ``isUnsatisfiable``
    /// distinguishes the two.
    public let retryAfter: Duration?

    /// How long until the key is back to its full burst, spending nothing
    /// further. What `X-RateLimit-Reset` reports.
    public let resetAfter: Duration

    public init(
        isAllowed: Bool,
        remaining: Int,
        retryAfter: Duration? = nil,
        resetAfter: Duration
    ) {
        self.isAllowed = isAllowed
        self.remaining = remaining
        self.retryAfter = retryAfter
        self.resetAfter = resetAfter
    }

    /// A denial that waiting cannot fix, because the call costs more than the
    /// quota's burst. A caller seeing this has a configuration bug rather
    /// than a busy client.
    public var isUnsatisfiable: Bool {
        !isAllowed && retryAfter == nil
    }
}
