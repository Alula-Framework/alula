extension Duration {
    /// This duration in seconds, fractions included — what `Date`
    /// arithmetic and `TimeInterval` want.
    ///
    /// `Double(components.seconds)` alone truncates: `.milliseconds(500)`
    /// becomes zero and `.milliseconds(1500)` one second. That shape was
    /// written out eight times under four names, and five more sites used
    /// the truncating one.
    package var inSeconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    /// Whole seconds, rounded **up**; zero or less is 0.
    ///
    /// The shape of `Retry-After` and of every "come back in N seconds"
    /// header: telling a client to wait zero seconds when it has 400 ms left
    /// earns a second refusal. Callers that must never say 0 apply their own
    /// floor.
    package var wholeSecondsRoundedUp: Int64 {
        let (seconds, attoseconds) = components
        guard seconds > 0 || attoseconds > 0 else { return 0 }
        return seconds + (attoseconds > 0 ? 1 : 0)
    }
}
