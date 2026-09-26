import AlulaMail
import Foundation
import Logging
import NIOCore
import ServiceLifecycle
import Synchronization

/// A few long-lived SMTP connections that every send shares (Relay #39).
///
/// `size` workers each hold at most one connection. A worker opens it when a
/// message arrives, sends `RSET` between messages, and closes it with `QUIT`
/// after `idleTimeout` with nothing to send or after `messagesPerConnection`
/// messages — servers limit both, and a connection they have dropped is only
/// discovered on the next write. One that turns out to be dead at `RSET`
/// costs a reconnect, not the message: that message is tried once more on a
/// fresh connection.
///
/// A refusal (`4xx`/`5xx` to a sender, recipient or message) fails only that
/// message; the connection carries on. A broken connection, a timeout, or a
/// failure to open fails the message it was carrying, transiently, and the
/// queue retries it.
///
/// Runs as ``AlulaMailSMTPModule``'s service. Before it starts and after it
/// stops, ``submit(_:_:)`` answers `false` and the transport opens a
/// connection for the one message, as it always did.
final class SMTPConnectionPool: Sendable {
    let settings: SMTPSettings
    let logger: Logger
    private let queue = SMTPJobQueue()

    init(settings: SMTPSettings, logger: Logger) {
        self.settings = settings
        self.logger = logger
    }

    /// Sends over a pooled connection. `false` when the pool is not running.
    func submit(_ message: MailMessage, _ data: Data) async throws -> Bool {
        let accepted = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Bool, any Error>) in
            let job = SMTPJob(message: message, data: data, continuation: continuation)
            if !queue.put(job) { continuation.resume(returning: false) }
        }
        return accepted
    }

    /// The workers, until graceful shutdown (queued messages are still sent)
    /// or cancellation (they fail, transiently, and the queue retries them).
    func run() async {
        queue.open()
        await withGracefulShutdownHandler {
            await withDiscardingTaskGroup { group in
                for _ in 0..<settings.poolSize {
                    group.addTask { await self.worker() }
                }
            }
        } onGracefulShutdown: {
            self.queue.close()
        }
        queue.close()
        queue.failAll(MailError.transient("SMTP connection pool stopped"))
    }

    private struct StaleConnection: Error {
        let job: SMTPJob
    }

    private func worker() async {
        while let first = await queue.take(within: nil) {
            var carried: SMTPJob? = first
            do {
                try await SMTPSession.withConnection(settings: settings, logger: logger) {
                    connection in
                    try await self.serve(&carried, over: connection)
                }
            } catch let stale as StaleConnection {
                if stale.job.retried {
                    stale.job.fail(MailError.transient("SMTP connection lost, twice"))
                } else {
                    queue.putFirst(stale.job.retrying())
                }
            } catch {
                // Opening the connection failed, with a message waiting on it.
                carried?.fail(Self.mailError(error))
            }
        }
    }

    /// Sends `carried`, then whatever else arrives, until idle or at the
    /// per-connection limit.
    private func serve(_ carried: inout SMTPJob?, over connection: SMTPConnection) async throws {
        var sent = 0
        while let job = carried {
            carried = nil
            if sent > 0 {
                do {
                    try await connection.reset()
                } catch {
                    throw StaleConnection(job: job)
                }
            }
            do {
                try await withDeadline(closing: connection.raw) {
                    try await connection.transaction(job.message, job.data)
                }
                job.succeed()
            } catch let refused as SMTPRefused {
                job.fail(refused.error)
            } catch {
                job.fail(Self.mailError(error))
                throw error  // the connection is in no known state
            }
            sent += 1
            if sent >= settings.messagesPerConnection { return }
            carried = await queue.take(within: settings.idleTimeout)
        }
    }

    /// Runs `body`, closing `channel` if it outlasts the timeout — the only
    /// way to abandon a read the server never answers.
    private func withDeadline<T>(closing channel: any Channel, _ body: () async throws -> T)
        async throws -> T
    {
        try await SMTPSession.withDeadline(settings.timeout, closing: channel, body)
    }

    static func mailError(_ error: any Error) -> MailError {
        switch error {
        case let refused as SMTPRefused: refused.error
        case let mail as MailError: mail
        default: MailError.transient("SMTP: \(error)")
        }
    }
}

/// A message waiting for a pooled connection, and whoever is waiting on it.
struct SMTPJob: Sendable {
    let message: MailMessage
    let data: Data
    let continuation: CheckedContinuation<Bool, any Error>
    var retried = false

    func succeed() { continuation.resume(returning: true) }
    func fail(_ error: MailError) { continuation.resume(throwing: error) }
    func retrying() -> SMTPJob {
        var copy = self
        copy.retried = true
        return copy
    }
}

/// First in, first out, with waiting workers and an idle timeout.
final class SMTPJobQueue: Sendable {
    private struct State {
        var jobs: [SMTPJob] = []
        var waiters: [(id: Int, continuation: CheckedContinuation<SMTPJob?, Never>)] = []
        var expired: Set<Int> = []
        var nextID = 0
        var isOpen = false
    }

    private let state = Mutex(State())

    func open() { state.withLock { $0.isOpen = true } }

    /// Stops taking new jobs. Queued ones are still handed out; idle
    /// workers are told there is nothing more.
    func close() {
        let idle = state.withLock { state -> [CheckedContinuation<SMTPJob?, Never>] in
            state.isOpen = false
            defer { state.waiters = [] }
            return state.waiters.map(\.continuation)
        }
        for waiter in idle { waiter.resume(returning: nil) }
    }

    /// `false` when closed: the caller sends without the pool.
    func put(_ job: SMTPJob) -> Bool {
        enum Outcome {
            case refused, queued
            case handed(CheckedContinuation<SMTPJob?, Never>)
        }
        let outcome = state.withLock { state -> Outcome in
            guard state.isOpen else { return .refused }
            if !state.waiters.isEmpty { return .handed(state.waiters.removeFirst().continuation) }
            state.jobs.append(job)
            return .queued
        }
        switch outcome {
        case .refused: return false
        case .queued: return true
        case .handed(let waiter):
            waiter.resume(returning: job)
            return true
        }
    }

    /// Back to the front: a message whose connection turned out to be dead.
    func putFirst(_ job: SMTPJob) {
        let waiter = state.withLock { state -> CheckedContinuation<SMTPJob?, Never>? in
            if !state.waiters.isEmpty { return state.waiters.removeFirst().continuation }
            state.jobs.insert(job, at: 0)
            return nil
        }
        waiter?.resume(returning: job)
    }

    /// The next job; `nil` after `within` with none, when closed and empty,
    /// or when cancelled.
    func take(within timeout: Duration?) async -> SMTPJob? {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        let timer = timeout.map { timeout in
            Task {
                try await Task.sleep(for: timeout)
                self.expire(id)
            }
        }
        defer {
            timer?.cancel()
            // An expiry that arrived after the job did left a marker.
            state.withLock { _ = $0.expired.remove(id) }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SMTPJob?, Never>) in
                enum Now {
                    case job(SMTPJob)
                    case nothing, wait
                }
                let now = state.withLock { state -> Now in
                    if !state.jobs.isEmpty { return .job(state.jobs.removeFirst()) }
                    if !state.isOpen || state.expired.remove(id) != nil { return .nothing }
                    state.waiters.append((id, continuation))
                    return .wait
                }
                switch now {
                case .job(let job): continuation.resume(returning: job)
                case .nothing: continuation.resume(returning: nil)
                case .wait: break
                }
            }
        } onCancel: {
            self.expire(id)
        }
    }

    private func expire(_ id: Int) {
        let waiter = state.withLock { state -> CheckedContinuation<SMTPJob?, Never>? in
            guard let index = state.waiters.firstIndex(where: { $0.id == id }) else {
                state.expired.insert(id)  // before it waited: it will not
                return nil
            }
            return state.waiters.remove(at: index).continuation
        }
        waiter?.resume(returning: nil)
    }

    /// Fails everything still queued.
    func failAll(_ error: MailError) {
        let jobs = state.withLock { state -> [SMTPJob] in
            defer { state.jobs = [] }
            return state.jobs
        }
        for job in jobs { job.fail(error) }
    }
}

/// The pool, as the mail module's service.
struct SMTPPoolService: Service {
    let pool: SMTPConnectionPool
    func run() async throws { await pool.run() }
}
