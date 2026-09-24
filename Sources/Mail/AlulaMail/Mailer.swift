import AlulaCore
import AlulaQueue
import Foundation
import Logging

/// Delivers a message: to an SMTP server, a provider's API, a log.
///
/// Throw ``MailError/permanent(_:)`` for a refusal no retry will change (the
/// address does not exist) and ``MailError/transient(_:)`` for one that might
/// (the server is busy). Mail sent through the queue is retried on anything
/// but a permanent refusal.
public protocol MailTransport: Sendable {
    func send(_ message: MailMessage) async throws
}

/// Sends mail. Inject it wherever mail goes out:
///
/// ```swift
/// @Service struct PasswordReset {
///     @Inject var mailer: Mailer
///     @Inject var jobs: JobQueue
///
///     func request(for account: Account, link: URL) async throws {
///         try await mailer.sendLater(
///             MailMessage(to: [account.email], subject: "Reset your password",
///                         text: "Within the hour: \(link)"),
///             via: jobs)
///     }
/// }
/// ```
///
/// `send` delivers now and throws if delivery fails. That suits a script, and
/// it does not suit a request, which then waits on an SMTP server and fails
/// when it does. `sendLater` enqueues a ``DeliverMail`` job instead. The
/// request returns at once, and a slow or unavailable mail server costs
/// retries rather than an error page. Add ``deliveryHandler`` to your
/// module's `queueHandlers` for the job to run.
public struct Mailer: Sendable {
    public let transport: any MailTransport
    /// Used when a message names no sender: `mail.from`.
    public let defaultFrom: MailAddress?

    public init(transport: any MailTransport, defaultFrom: MailAddress? = nil) {
        self.transport = transport
        self.defaultFrom = defaultFrom
    }

    /// Delivers `message` now. Fills in the default sender and validates
    /// before anything is sent.
    public func send(_ message: MailMessage) async throws {
        try await transport.send(prepared(message))
    }

    /// Enqueues `message` for delivery by a worker, retried under
    /// ``DeliverMail``'s policy. Validation happens here, so a message that
    /// could never be sent fails now rather than as a dead letter.
    @discardableResult
    public func sendLater(
        _ message: MailMessage, via jobs: JobQueue, options: EnqueueOptions = EnqueueOptions()
    ) async throws -> EnqueueResult {
        try await jobs.enqueue(DeliverMail(message: prepared(message)), options: options)
    }

    /// Runs ``DeliverMail`` jobs with this mailer. A permanent refusal
    /// discards the job instead of retrying it.
    public var deliveryHandler: QueueHandler {
        .handle(DeliverMail.self, timeout: .seconds(120)) { job, _ in
            do {
                try await transport.send(job.message)
            } catch MailError.permanent(let reason) {
                throw DiscardJob("mail refused: \(reason)")
            } catch let error as MailError where error.isInvalid {
                throw DiscardJob(error.description)
            }
        }
    }

    func prepared(_ message: MailMessage) throws -> MailMessage {
        var message = message
        if message.from == nil { message.from = defaultFrom }
        try message.validate()
        return message
    }
}

/// A message waiting to be delivered: `Mailer.sendLater`'s job. On the
/// `mail` queue, retried for about a day. A mail server down for a few hours
/// should delay a password reset, not lose it.
public struct DeliverMail: QueuedJob {
    public static let kind = "alula.mail.deliver"
    public static let queue = "mail"
    public static let retry = RetryPolicy(maxAttempts: 12, base: .seconds(30), cap: .seconds(4 * 3600))

    public let message: MailMessage

    public init(message: MailMessage) { self.message = message }
}

extension MailError {
    var isInvalid: Bool {
        switch self {
        case .invalidAddress, .invalidMessage: true
        case .permanent, .transient: false
        }
    }
}

/// Writes each message to the log instead of sending it: the development
/// transport, so a password-reset link can be read off the console.
public struct LoggingMailTransport: MailTransport {
    let logger: Logger

    public init(logger: Logger = Logger(label: "alula.mail")) {
        self.logger = logger
    }

    public func send(_ message: MailMessage) async throws {
        logger.info(
            "mail not sent — logged instead (development transport)",
            metadata: [
                "to": "\(message.recipients.map(\.address).joined(separator: ", "))",
                "subject": "\(message.subject)",
                "text": "\(message.text ?? "(no text part)")",
            ])
    }
}

/// Provides the ``Mailer``.
///
/// The transport comes from whichever module provides a ``MailTransport``,
/// for instance `AlulaMailSMTPModule` (trait `SMTP`). With none, development
/// and test log each message instead of sending it. Anywhere else this module
/// fails composition, rather than let password resets vanish into a log. Set
/// `mail.transport: log` to choose logging on purpose, such as in a staging
/// environment with no mail server.
///
/// ```yaml
/// mail:
///   from: "Example <no-reply@example.com>"
/// ```
public struct AlulaMailModule: AlulaModule {
    public let mailer: Mailer

    public init(configuration: Configuration, transport: (any MailTransport)? = nil) throws {
        let from = try configuration.getIfPresent("mail.from", as: String.self)
            .map(MailAddress.parse)
        if let transport {
            self.mailer = Mailer(transport: transport, defaultFrom: from)
            return
        }
        let environment = configuration.environment ?? AlulaEnvironment.current()
        let chosen = try configuration.getIfPresent("mail.transport", as: String.self)
        guard environment == .dev || environment == .test || chosen == "log" else {
            throw MailConfigurationError.noTransport(environment: environment.rawValue)
        }
        self.mailer = Mailer(transport: LoggingMailTransport(), defaultFrom: from)
    }

    public init() {
        preconditionFailure(
            "AlulaMailModule takes its configuration in init(configuration:transport:), so it "
                + "cannot be instantiated from its type. Pass `composedBy: alulaComposeModules` "
                + "to Alula.run.")
    }
}

public enum MailConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
    case noTransport(environment: String)

    public var description: String {
        switch self {
        case .noTransport(let environment):
            """
            no mail transport in the \(environment) environment: nothing would be delivered. Add \
            AlulaMailSMTPModule (configured under mail.smtp.*) or another module providing a \
            MailTransport, or set mail.transport: log to log mail on purpose.
            """
        }
    }
}

extension MailAddress {
    /// `"Name <address>"` or a bare `address`, as configuration writes it.
    public static func parse(_ text: String) throws -> MailAddress {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(">"), let open = trimmed.lastIndex(of: "<") else {
            return try MailAddress(trimmed)
        }
        let address = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
        var name = trimmed[..<open].trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
            name = String(name.dropFirst().dropLast())
        }
        return try MailAddress(address, name: name.isEmpty ? nil : name)
    }
}
