import Synchronization

/// When the application's graceful shutdown has to be finished by.
///
/// `lifecycle.shutdown-timeout-seconds` bounds the whole shutdown. Past it,
/// ServiceLifecycle cancels every service still running at once — the
/// database pool included — so work that was still going cannot even record
/// that it stopped (Relay #36). A service that holds work it could hand back
/// reads ``current`` and hands it back *before* the deadline, while what it
/// needs is still up. The queue worker does this with its running jobs.
///
/// Set for every service of an application Alula runs, and `nil` outside one
/// (a test driving a service by hand). ``deadline`` is `nil` until shutdown
/// begins, and stays `nil` when no timeout is configured.
public final class ShutdownDeadline: Sendable {
    @TaskLocal public static var current: ShutdownDeadline?

    /// `lifecycle.shutdown-timeout-seconds`, if set.
    public let timeout: Duration?
    private let began = Mutex<ContinuousClock.Instant?>(nil)
    private let cut = Mutex<[String]>([])

    public init(timeout: Duration?) {
        self.timeout = timeout
    }

    /// Marks the start of graceful shutdown. Only the first call counts.
    public func begin(at instant: ContinuousClock.Instant = .now) {
        began.withLock { if $0 == nil { $0 = instant } }
    }

    /// The instant shutdown must be finished by: when it began plus the
    /// timeout. `nil` before shutdown begins, or with no timeout.
    public var deadline: ContinuousClock.Instant? {
        guard let timeout else { return nil }
        return began.withLock { $0 }.map { $0 + timeout }
    }

    /// Whether shutdown began and ran past its deadline.
    public func overran(at instant: ContinuousClock.Instant = .now) -> Bool {
        deadline.map { instant > $0 } ?? false
    }

    var hasBegun: Bool { began.withLock { $0 != nil } }

    /// Records that a module's service was still running when shutdown gave
    /// up on it and cancelled it.
    func noteCancelled(_ module: String) {
        cut.withLock { $0.append(module) }
    }

    /// The modules whose services were cancelled rather than allowed to
    /// finish, in the order they ended.
    var cancelledModules: [String] { cut.withLock { $0 } }
}

/// Shutdown ran past `lifecycle.shutdown-timeout-seconds`, so whatever was
/// still running was cancelled rather than allowed to finish.
struct ShutdownTimedOut: Error, CustomStringConvertible {
    let timeout: Duration
    let modules: [String]

    var description: String {
        "shutdown did not finish within \(timeout) (lifecycle.shutdown-timeout-seconds); "
            + "still running, and cancelled: \(modules.joined(separator: ", ")). Raise the timeout "
            + "above the longest job or request, or make that work stop sooner."
    }
}
