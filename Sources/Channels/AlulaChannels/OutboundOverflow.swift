/// What a socket does when its outbound queue is full.
///
/// The queue is bounded — an unbounded one let a single stalled subscriber
/// exhaust the server's memory — so something has to give when a client
/// falls behind the rate being published to it. The question is whether the
/// client is told.
public enum OutboundOverflow: Sendable, Equatable {
    /// Close the connection, so the client reconnects and resynchronises.
    ///
    /// The default, because the alternative is undetectable. `Envelope`
    /// carries no sequence number, so a dropped broadcast leaves no trace a
    /// client could notice: its view is silently wrong and it has no reason
    /// to suspect it. A close is visible, and the reference client's
    /// reconnect re-joins every topic and delivers each channel's fresh
    /// `initialState` — which is the resynchronisation that dropping quietly
    /// denies it.
    ///
    /// The server-side counters and logs are unchanged; what changes is that
    /// the client learns about it too.
    case closeSocket

    /// Drop the oldest queued frames and keep the connection open.
    ///
    /// What Channels did before there was a choice, and still right for a
    /// feed where only the latest value means anything — a cursor position,
    /// a metrics tick, a progress bar — and where a client rendering a
    /// slightly stale value is better than one reconnecting. Wrong for
    /// anything where a message is an *event* rather than a sample, because
    /// there the gap is the bug.
    case dropOldest
}
