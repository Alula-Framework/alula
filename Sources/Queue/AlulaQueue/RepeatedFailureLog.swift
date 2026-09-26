import Foundation
import Logging
import Synchronization

/// Logs a failure that repeats every poll as a change of state, not as a
/// stream.
///
/// The worker polls each queue every `poll-interval`. While the database was
/// down it logged "could not claim jobs" at `error` for every queue on every
/// poll — 68 lines in 45 seconds from one node, burying the data source's own
/// reconnect warnings, which said what was actually wrong (Relay #42). Now:
///
/// - the first failure is logged at `error`, with the error;
/// - a failure with a different error is logged again: it is news;
/// - the same failure repeating is counted, and summarized at `warning`
///   once every ``reminderInterval`` while it lasts;
/// - the first success afterwards is logged at `info`, with how many
///   attempts failed and for how long.
final class RepeatedFailureLog: Sendable {
    /// What failed, as a log line reads: "could not claim jobs".
    let what: String
    /// The reminder while it lasts: "still cannot claim jobs".
    let still: String
    /// What it is doing again once it works: "claiming jobs again".
    let recovered: String
    let reminderInterval: Duration
    let logger: Logger

    private struct Failing {
        var since: ContinuousClock.Instant
        var lastLogged: ContinuousClock.Instant
        var count: Int
        var error: String
    }

    private let state = Mutex<Failing?>(nil)

    init(
        what: String, still: String, recovered: String, reminderInterval: Duration = .seconds(60),
        logger: Logger
    ) {
        self.what = what
        self.still = still
        self.recovered = recovered
        self.reminderInterval = reminderInterval
        self.logger = logger
    }

    func failed(
        _ error: any Error, metadata: Logger.Metadata = [:], at now: ContinuousClock.Instant = .now
    ) {
        let description = String(describing: error)
        enum Action {
            case first, changed
            case remind(count: Int, since: ContinuousClock.Instant)
            case quiet
        }
        let action = state.withLock { failing -> Action in
            guard var current = failing else {
                failing = Failing(since: now, lastLogged: now, count: 1, error: description)
                return .first
            }
            current.count += 1
            defer { failing = current }
            if current.error != description {
                current.error = description
                current.lastLogged = now
                return .changed
            }
            if now - current.lastLogged >= reminderInterval {
                current.lastLogged = now
                return .remind(count: current.count, since: current.since)
            }
            return .quiet
        }
        var metadata = metadata
        metadata["error"] = "\(description)"
        switch action {
        case .first, .changed:
            logger.error("\(what)", metadata: metadata)
        case .remind(let count, let since):
            metadata["failures"] = "\(count)"
            metadata["failing-for"] = "\(Self.seconds(now - since))"
            logger.warning("\(still)", metadata: metadata)
        case .quiet:
            break
        }
    }

    func succeeded(at now: ContinuousClock.Instant = .now) {
        guard
            let ended = state.withLock({ failing -> Failing? in
                defer { failing = nil }
                return failing
            })
        else { return }
        logger.info(
            "\(recovered)",
            metadata: [
                "failures": "\(ended.count)", "failed-for": "\(Self.seconds(now - ended.since))",
            ])
    }

    /// "42.0 seconds", not "42.028647206 seconds".
    static func seconds(_ duration: Duration) -> String {
        let (whole, fraction) = duration.components
        let value = Double(whole) + Double(fraction) / 1e18
        return String(format: "%.1f seconds", value)
    }
}
