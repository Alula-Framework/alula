import AlulaMail
import Synchronization

/// A `MailTransport` that keeps what it is given, for assertions, and can
/// be told to fail.
///
/// ```swift
/// let transport = RecordingMailTransport()
/// let mailer = Mailer(transport: transport, defaultFrom: try MailAddress("app@example.com"))
/// try await PasswordReset(mailer: mailer, jobs: harness.queue).request(for: account, link: link)
/// await harness.drain()   // a QueueTestHarness with mailer.deliveryHandler
/// #expect(transport.sent.first?.subject == "Reset your password")
/// ```
public final class RecordingMailTransport: MailTransport {
    private struct State {
        var sent: [MailMessage] = []
        var failures: [MailError] = []
    }
    private let state = Mutex(State())

    /// A transport that has sent nothing and will not fail.
    public init() {}

    /// Every message delivered, in order.
    public var sent: [MailMessage] { state.withLock { $0.sent } }

    /// The next sends throw these, one each, before delivery resumes.
    public func fail(with errors: MailError...) {
        state.withLock { $0.failures += errors }
    }

    /// Throws the next queued failure, if any, and records nothing; otherwise
    /// records `message` as given. It does not validate: `Mailer` has.
    public func send(_ message: MailMessage) async throws {
        let failure = state.withLock { state -> MailError? in
            guard !state.failures.isEmpty else {
                state.sent.append(message)
                return nil
            }
            return state.failures.removeFirst()
        }
        if let failure { throw failure }
    }
}
