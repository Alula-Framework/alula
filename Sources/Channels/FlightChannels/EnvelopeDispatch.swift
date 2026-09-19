import Synchronization

/// How a socket's inbound envelopes are ordered against each other.
///
/// The frame loop used to handle one envelope completely before reading the
/// next, which made a socket's whole traffic strictly ordered — and made one
/// slow channel handler stall every other topic on that connection.
public enum EnvelopeDispatch: Sendable, Equatable {
    /// One envelope at a time, socket-wide. What Channels did before there
    /// was a choice, kept for a protocol whose topics are not independent.
    case serialPerSocket

    /// In order within a topic, concurrent across topics.
    ///
    /// The ordering that a stateful channel actually needs: `flight:join`
    /// then a push on the same topic still arrive in that order, and a
    /// `Channel` instance is never called re-entrantly, so handlers keep the
    /// serialization they were written against. What is given up is ordering
    /// *between* topics, which are independent by construction.
    ///
    /// `maxConcurrent` bounds how many envelopes a single socket can have in
    /// flight. The frame loop waits when the bound is reached, and because
    /// inbound frames pull rather than buffer, that wait reaches the socket:
    /// a client that floods one connection is slowed by TCP rather than
    /// given unbounded work to queue.
    case serialPerTopic(maxConcurrent: Int)

    /// Per-topic, sixteen in flight.
    public static let `default` = EnvelopeDispatch.serialPerTopic(maxConcurrent: 16)

    var maxConcurrent: Int {
        switch self {
        case .serialPerSocket: return 1
        case .serialPerTopic(let limit): return max(1, limit)
        }
    }

    var isConcurrent: Bool {
        if case .serialPerTopic = self { return true }
        return false
    }
}

/// A counting semaphore over envelopes in flight for one socket.
///
/// Slots are handed from a finishing envelope straight to a waiting one
/// rather than released and re-acquired, so the count cannot drift under
/// contention.
actor EnvelopeGate {
    private let capacity: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func acquire() async {
        if inFlight < capacity {
            inFlight += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            inFlight -= 1
        } else {
            // The slot transfers; `inFlight` is unchanged because one
            // envelope left and one started.
            waiters.removeFirst().resume()
        }
    }

    /// Wakes everything still queued, for teardown. Without it a frame loop
    /// cancelled while waiting for a slot would never resume.
    func drain() {
        let queued = waiters
        waiters = []
        inFlight = 0
        for waiter in queued { waiter.resume() }
    }
}
