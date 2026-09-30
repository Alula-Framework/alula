import AlulaCore
import AlulaQueue
import Foundation
import Logging

/// Delivers a message: to an SMTP server, a provider's API, a log.
///
/// Throw ``MailError/permanent(_:)`` for a refusal no retry will change (the
/// address does not exist) and ``MailError/transient(_:)`` for one that might
/// (the server is busy). Mail sent through the queue is retried on anything
/// but a permanent refusal, ``MailError/invalidAddress(_:)`` or
/// ``MailError/invalidMessage(_:)``; an error that is not a ``MailError`` is
/// retried too.
///
/// Throw only when the message was not accepted. An error after the
/// receiving server may have taken it (a lost reply, a timeout after the
/// body went out) should still be transient, and then the retry can deliver
/// a second copy.
public protocol MailTransport: Sendable {
    /// Hands `message` to the mail system. Returning means it was accepted
    /// for delivery, not that it reached the inbox.
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
    /// Where messages go: whichever module's ``MailTransport``, or the
    /// logging one.
    public let transport: any MailTransport
    /// Used when a message names no sender: `mail.from`.
    public let defaultFrom: MailAddress?

    /// A mailer over `transport`. ``AlulaMailModule`` builds the
    /// application's; build one directly in a test or a tool.
    public init(transport: any MailTransport, defaultFrom: MailAddress? = nil) {
        self.transport = transport
        self.defaultFrom = defaultFrom
    }

    /// Delivers `message` now. Fills in the default sender and validates
    /// before anything is sent.
    ///
    /// Not retried: whatever the transport throws reaches the caller, and
    /// the message is not kept. A message that fails
    /// ``MailMessage/validate()``, with the default sender applied, throws
    /// ``MailError/invalidMessage(_:)`` before the transport sees it.
    public func send(_ message: MailMessage) async throws {
        try await transport.send(prepared(message))
    }

    /// Enqueues `message` for delivery by a worker, retried under
    /// ``DeliverMail``'s policy. Validation happens here, so a message that
    /// could never be sent fails now rather than as a dead letter.
    ///
    /// Returning means the job is stored, not that mail went out. If the
    /// enqueue itself fails, the queue's error is thrown and nothing is
    /// stored. Each call enqueues a new job unless `options.uniqueKey` joins
    /// it to one already waiting. Delivery is at least once; see
    /// ``Mailer/deliveryHandler``.
    @discardableResult
    public func sendLater(
        _ message: MailMessage, via jobs: JobQueue, options: EnqueueOptions = EnqueueOptions()
    ) async throws -> EnqueueResult {
        try await jobs.enqueue(DeliverMail(message: prepared(message)), options: options)
    }

    /// Runs ``DeliverMail`` jobs with this mailer. A permanent refusal, or a
    /// message the transport finds invalid, discards the job instead of
    /// retrying it; any other error is retried.
    ///
    /// **At least once, so a recipient can get two copies.** The queue runs a
    /// job again when its worker dies or its attempt fails, and an attempt
    /// can fail after the server accepted the message: the reply to the
    /// final `.` lost, or the attempt past this handler's 120-second
    /// timeout. With the SMTP pool, a message still waiting for a
    /// connection when the attempt times out is not withdrawn, and is sent
    /// as well as the retry. `SMTPMailTransport` renders a new `Message-ID`
    /// on each attempt, so the copies do not share one. See Docs/mail.md and Docs/queue.md.
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
/// `mail` queue, retried for about twelve hours. A mail server down for a
/// few hours should delay a password reset, not lose it.
///
/// Twelve attempts, the waits between them 30 seconds doubling to a 4-hour
/// cap (±10%). After the last, the job is discarded and the message is not
/// sent.
public struct DeliverMail: QueuedJob {
    /// `alula.mail.deliver`, fixed so renaming the type strands no jobs.
    public static let kind = "alula.mail.deliver"
    /// `mail`, so mail has its own concurrency (`queue.queues.mail.concurrency`).
    public static let queue = "mail"
    /// Twelve attempts, 30 seconds doubling to a 4-hour cap.
    public static let retry = RetryPolicy(maxAttempts: 12, base: .seconds(30), cap: .seconds(4 * 3600))

    /// The message, sender filled in and already validated.
    public let message: MailMessage

    /// A job for `message`. `Mailer.sendLater` validates first; building
    /// one directly does not.
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
///
/// **The body carries whatever the message does**: reset and sign-in links,
/// verification tokens, personal data. Logged, it goes wherever the logs go
/// and stays as long as they are kept. With `logBody: false` only the
/// recipients, subject and body size are logged. `AlulaMailModule` turns the
/// body off everywhere but a *declared* development or test environment
/// (`Configuration.isExplicitlyDevelopment()`) unless `mail.log-body: true`.
public struct LoggingMailTransport: MailTransport {
    let logger: Logger
    let logBody: Bool

    /// A transport that logs at `info` to `logger`. Only the text part is
    /// logged; an HTML-only message logs `(no text part)`.
    public init(logger: Logger = Logger(label: "alula.mail"), logBody: Bool = true) {
        self.logger = logger
        self.logBody = logBody
    }

    /// Logs the recipients, subject and text body (or its size), and never
    /// throws.
    public func send(_ message: MailMessage) async throws {
        var metadata: Logger.Metadata = [
            "to": "\(message.recipients.map(\.address).joined(separator: ", "))",
            "subject": "\(message.subject)",
        ]
        if logBody {
            metadata["text"] = "\(message.text ?? "(no text part)")"
        } else {
            metadata["text"] = "(withheld: \(message.text?.utf8.count ?? 0) bytes; mail.log-body is off)"
        }
        logger.info("mail not sent — logged instead (logging transport)", metadata: metadata)
    }
}

/// Provides the ``Mailer``.
///
/// The transport comes from whichever module provides a ``MailTransport``,
/// for instance `AlulaMailSMTPModule` (trait `SMTP`). With none, a declared
/// development or test environment — `ALULA_ENV` set to `dev`,
/// `development`, `test` or `local` (`Configuration.isExplicitlyDevelopment()`)
/// — logs each message instead of sending it. Anywhere else, an unset
/// `ALULA_ENV` included, this module fails composition with
/// ``MailConfigurationError/noTransport(environment:)``, rather than let
/// password resets vanish into a log. `alula dev` sets `ALULA_ENV=dev`. Set
/// `mail.transport: log` to choose logging on purpose, such as in a staging
/// environment with no mail server. There the message bodies are withheld
/// from the log, since they carry reset links and personal data, unless
/// `mail.log-body: true`.
///
/// ```yaml
/// mail:
///   from: "Example <no-reply@example.com>"
/// ```
public struct AlulaMailModule: AlulaModule {
    /// The mailer the graph provides.
    public let mailer: Mailer

    /// The composition root's initializer. `transport` is whichever module's
    /// ``MailTransport``.
    ///
    /// - Throws: ``MailConfigurationError/noTransport(environment:)`` when
    ///   `transport` is nil, `mail.transport` is not `log` and the
    ///   environment is not a declared development one; ``MailError`` when
    ///   `mail.from` does not parse.
    public init(configuration: Configuration, transport: (any MailTransport)? = nil) throws {
        let from = try configuration.getIfPresent("mail.from", as: String.self)
            .map(MailAddress.parse)
        if let transport {
            self.mailer = Mailer(transport: transport, defaultFrom: from)
            return
        }
        // Development only when the environment was *declared* one: a
        // production box that forgets ALULA_ENV resolves to dev for its
        // overlay file, and must not quietly log mail instead of sending it.
        let development = configuration.isExplicitlyDevelopment()
        let chosen = try configuration.getIfPresent("mail.transport", as: String.self)
        guard development || chosen == "log" else {
            let environment = configuration.declaredEnvironment()?.rawValue ?? "undeclared"
            throw MailConfigurationError.noTransport(environment: environment)
        }
        // Bodies carry reset links and personal data; outside a declared
        // development or test environment they stay out of the log unless
        // asked for.
        let logBody =
            try configuration.getIfPresent("mail.log-body", as: Bool.self) ?? development
        self.mailer = Mailer(transport: LoggingMailTransport(logBody: logBody), defaultFrom: from)
    }

    /// Unavailable: a hand-written call is a compile error saying how to
    /// build this module, and the composer never counts it as a candidate.
    @available(*, unavailable, message: "AlulaMailModule takes its configuration in init(configuration:transport:), so it cannot be instantiated from its type. Pass `composedBy: alulaComposeModules` to Alula.run.")
    public init() { fatalError("unavailable") }
}

/// Why ``AlulaMailModule`` refused to compose.
public enum MailConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No module provides a ``MailTransport``, `mail.transport` is not
    /// `log`, and the environment was not declared as a development or test
    /// one. `environment` is the declared environment's name, or
    /// `"undeclared"` when none was set.
    case noTransport(environment: String)

    /// Names the environment and the three ways out.
    public var description: String {
        switch self {
        case .noTransport(let environment) where environment == "undeclared":
            """
            no mail transport, and no environment was declared: nothing would be delivered. Add \
            AlulaMailSMTPModule (configured under mail.smtp.*) or another module providing a \
            MailTransport, set mail.transport: log to log mail on purpose, or declare a \
            development environment (ALULA_ENV=dev) when running locally.
            """
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

extension MailConfigurationError: ModuleConfigurationError {}
