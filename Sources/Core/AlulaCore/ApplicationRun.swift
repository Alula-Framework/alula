import Synchronization

/// What the application's services did, so the report on exit can say which
/// of them ended it and after how long.
///
/// Every error that ended `Alula.run` was reported as `alula: could not
/// start.` — including a module failing after the application had served for
/// three days, which sent the reader looking at configuration and
/// connectivity for a process that had started fine. This records when every
/// service had started, which module failed first, and which service simply
/// returned, and the bootstrap turns those into the right report.
final class ApplicationRun: Sendable {
    @TaskLocal static var current: ApplicationRun?

    private struct State {
        var entered = 0
        var startedAt: ContinuousClock.Instant?
        var firstFailure: (module: String, error: any Error)?
        var endedOnItsOwn: String?
    }

    let expected: Int
    private let state = Mutex(State())

    /// How long after every service has been entered a failure still counts
    /// as a failed start. Entering is not being up: a server binds its port,
    /// a pool dials, a client connects in the first moments of `run()`, and
    /// a failure there is a start that did not work — reported as "could not
    /// start", not "stopped after running 12 ms".
    static let startupWindow = Duration.seconds(1)

    init(expected: Int) {
        self.expected = expected
    }

    /// A module's service was entered: its startup hooks done.
    func moduleStarted(at instant: ContinuousClock.Instant = .now) {
        state.withLock { state in
            state.entered += 1
            if state.entered == expected, state.startedAt == nil { state.startedAt = instant }
        }
    }

    func moduleFailed(_ module: String, _ error: any Error) {
        state.withLock { state in
            if state.firstFailure == nil { state.firstFailure = (module, error) }
        }
    }

    func moduleEndedOnItsOwn(_ module: String) {
        state.withLock { state in
            if state.endedOnItsOwn == nil { state.endedOnItsOwn = module }
        }
    }

    /// When every service had started; `nil` if the application never got
    /// that far.
    var startedAt: ContinuousClock.Instant? { state.withLock { $0.startedAt } }
    var firstFailure: (module: String, error: any Error)? { state.withLock { $0.firstFailure } }
    var endedOnItsOwn: String? { state.withLock { $0.endedOnItsOwn } }

    /// The error to report for `error`, which ended the service group:
    /// unchanged for a start that never completed, or one that says the
    /// application had been running, which module stopped it, and for how
    /// long.
    func explain(_ error: any Error, at now: ContinuousClock.Instant = .now) -> any Error {
        let uptime = startedAt.map { now - $0 }.flatMap { $0 >= Self.startupWindow ? $0 : nil }
        if let module = endedOnItsOwn, firstFailure == nil {
            return ServiceEndedOnItsOwn(module: module, uptime: uptime)
        }
        guard let uptime else { return error }
        let failure = firstFailure
        return StoppedWhileRunning(
            module: failure?.module, uptime: uptime, underlying: failure?.error ?? error)
    }
}

/// The application had started, then a module failed.
struct StoppedWhileRunning: Error, CustomStringConvertible {
    let module: String?
    let uptime: Duration
    let underlying: any Error

    var headline: String {
        "stopped after running \(formatUptime(uptime))"
            + (module.map { ": \($0) failed." } ?? ": a service failed.")
    }

    var description: String { "\(headline)\n\(underlying)" }
}

/// A module's service returned though it is meant to run until shutdown.
struct ServiceEndedOnItsOwn: Error, CustomStringConvertible {
    let module: String
    /// `nil` when it ended before every service had started.
    let uptime: Duration?

    var headline: String {
        (uptime.map { "stopped after running \(formatUptime($0)): " } ?? "could not start: ")
            + "\(module)'s service ended on its own."
    }

    static let explanation = [
        "A module's service runs until the application shuts down, unless the module",
        "declares `serviceCompletion: .endsApp` for a bounded job. Returning early",
        "stops the application.",
    ]

    var description: String { ([headline] + Self.explanation).joined(separator: "\n") }
}

/// "3d 4h 12m", "4m 07s", "850 ms": the largest units that matter.
func formatUptime(_ duration: Duration) -> String {
    let (seconds, attoseconds) = duration.components
    if seconds < 1 { return "\(attoseconds / 1_000_000_000_000_000) ms" }
    let days = seconds / 86_400
    let hours = seconds % 86_400 / 3_600
    let minutes = seconds % 3_600 / 60
    let secs = seconds % 60
    if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m \(secs < 10 ? "0" : "")\(secs)s" }
    return "\(secs)s"
}
