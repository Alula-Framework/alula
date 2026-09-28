import AlulaCore
import AlulaMail
import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import ServiceLifecycle
import Synchronization

/// `mail.smtp.*`.
///
/// ```yaml
/// mail:
///   smtp:
///     host: smtp.example.com
///     port: 587                  # default: 587 starttls, 465 tls, 25 none
///     security: starttls         # starttls | tls | none
///     username: apikey
///     password: ${SMTP_PASSWORD} # or ALULA_MAIL_SMTP_PASSWORD
///     timeout-seconds: 30
///     pool-size: 4               # long-lived connections; 0 = one per message
///     idle-seconds: 30           # close a pooled connection idle this long
///     messages-per-connection: 100
/// ```
public struct SMTPSettings: Sendable, Equatable {
    public enum Security: String, Sendable, Equatable {
        /// Connect in plaintext, then upgrade with `STARTTLS` before anything
        /// else is said. Refuses a server that does not offer it.
        case startTLS = "starttls"
        /// TLS from the first byte (SMTPS, usually port 465).
        case implicitTLS = "tls"
        /// No encryption: a local relay or a test server only. Credentials
        /// are then sent in cleartext; see ``SMTPSettings/allowPlaintextAuth``.
        case none
    }

    public var host: String
    public var port: Int
    public var security: Security
    public var username: String?
    public var password: String?
    /// The name this client gives in `EHLO`.
    public var heloName: String
    /// How long the server may take. Without the pool, the whole session
    /// (greeting, `EHLO`, TLS, `AUTH`, the message) must fit in it. With the
    /// pool, opening a connection and each message get it separately; time
    /// spent waiting for a pooled connection does not count. The TCP
    /// connect itself gives up after 10 seconds. Running out is
    /// `MailError.transient`.
    public var timeout: Duration
    /// Off only for a test server with a self-signed certificate. Applies to
    /// both `starttls` and `tls`.
    public var verifyCertificates: Bool
    /// Credentials over an unencrypted connection. Off unless asked for.
    ///
    /// ``SMTPSettings/init(configuration:)`` refuses a username with
    /// `security: none` at startup unless this is on. Settings built in code
    /// are checked where it matters: with this off, the transport refuses to
    /// authenticate over a `.none` connection, sending no credentials, and
    /// the send fails with `MailError.transient`.
    public var allowPlaintextAuth: Bool
    /// The right-hand side of generated `Message-ID`s.
    public var messageIDDomain: String
    /// How many long-lived connections ``AlulaMailSMTPModule`` keeps; `0`
    /// opens one per message.
    public var poolSize: Int
    /// A pooled connection with nothing to send for this long is closed.
    /// Below the idle limit of most servers (a few minutes), so the pool
    /// closes first.
    public var idleTimeout: Duration
    /// A pooled connection is closed and reopened after this many messages;
    /// servers limit messages per session.
    public var messagesPerConnection: Int

    public init(
        host: String, port: Int? = nil, security: Security = .startTLS, username: String? = nil,
        password: String? = nil, heloName: String = "localhost", timeout: Duration = .seconds(30),
        verifyCertificates: Bool = true, allowPlaintextAuth: Bool = false,
        messageIDDomain: String? = nil, poolSize: Int = 4, idleTimeout: Duration = .seconds(30),
        messagesPerConnection: Int = 100
    ) {
        self.host = host
        self.port =
            port
            ?? {
                switch security {
                case .startTLS: 587
                case .implicitTLS: 465
                case .none: 25
                }
            }()
        self.security = security
        self.username = username
        self.password = password
        self.heloName = heloName
        self.timeout = timeout
        self.verifyCertificates = verifyCertificates
        self.allowPlaintextAuth = allowPlaintextAuth
        self.messageIDDomain = messageIDDomain ?? host
        self.poolSize = poolSize
        self.idleTimeout = idleTimeout
        self.messagesPerConnection = messagesPerConnection
    }

    /// Reads `mail.smtp.*`. Throws ``SMTPConfigurationError`` when the host
    /// is missing, `security` is not `starttls`, `tls` or `none`, a count or
    /// duration is out of range, or a username is set with `security: none`
    /// and `allow-plaintext-auth` is not `true`.
    public init(configuration: Configuration) throws {
        guard let host = try configuration.getIfPresent("mail.smtp.host", as: String.self) else {
            throw SMTPConfigurationError("mail.smtp.host is required")
        }
        let rawSecurity =
            try configuration.getIfPresent("mail.smtp.security", as: String.self) ?? "starttls"
        guard let security = Security(rawValue: rawSecurity.lowercased()) else {
            throw SMTPConfigurationError(
                "mail.smtp.security must be starttls, tls or none; it is \(rawSecurity)")
        }
        let timeout = try configuration.getIfPresent("mail.smtp.timeout-seconds", as: Int.self) ?? 30
        guard timeout > 0 else {
            throw SMTPConfigurationError("mail.smtp.timeout-seconds must be positive")
        }
        let poolSize = try configuration.getIfPresent("mail.smtp.pool-size", as: Int.self) ?? 4
        guard poolSize >= 0 else {
            throw SMTPConfigurationError("mail.smtp.pool-size must be 0 or more; it is \(poolSize)")
        }
        let idle = try configuration.getIfPresent("mail.smtp.idle-seconds", as: Int.self) ?? 30
        guard idle > 0 else {
            throw SMTPConfigurationError("mail.smtp.idle-seconds must be positive")
        }
        let perConnection =
            try configuration.getIfPresent("mail.smtp.messages-per-connection", as: Int.self) ?? 100
        guard perConnection > 0 else {
            throw SMTPConfigurationError("mail.smtp.messages-per-connection must be positive")
        }
        self.init(
            host: host, port: try configuration.getIfPresent("mail.smtp.port", as: Int.self),
            security: security,
            username: try configuration.getIfPresent("mail.smtp.username", as: String.self),
            password: try configuration.getIfPresent("mail.smtp.password", as: String.self),
            heloName: try configuration.getIfPresent("mail.smtp.helo-name", as: String.self)
                ?? "localhost",
            timeout: .seconds(timeout),
            verifyCertificates: try configuration.getIfPresent(
                "mail.smtp.verify-certificates", as: Bool.self) ?? true,
            allowPlaintextAuth: try configuration.getIfPresent(
                "mail.smtp.allow-plaintext-auth", as: Bool.self) ?? false,
            messageIDDomain: try configuration.getIfPresent(
                "mail.smtp.message-id-domain", as: String.self),
            poolSize: poolSize, idleTimeout: .seconds(idle), messagesPerConnection: perConnection)
        if username != nil, security == .none, !allowPlaintextAuth {
            throw SMTPConfigurationError(
                """
                mail.smtp.username is set with security: none, which sends the password in \
                cleartext. Use starttls or tls, or set mail.smtp.allow-plaintext-auth: true for \
                a local relay.
                """)
        }
    }
}

/// A `mail.smtp.*` value that cannot be used, reported at startup.
public struct SMTPConfigurationError: Error, Sendable, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// Sends mail over SMTP (RFC 5321): `STARTTLS` or implicit TLS, `AUTH PLAIN`
/// or `LOGIN`, and SMTPUTF8 when an address needs it.
///
/// With a pool (``AlulaMailSMTPModule`` runs one, `mail.smtp.pool-size`),
/// messages go over a few long-lived connections, `RSET` between them.
/// Without one — `pool-size: 0`, a transport built by hand, or a command
/// that does not start the pool — each message gets its own connection.
/// Opening one costs a TCP handshake, TLS, `EHLO` and `AUTH`; against a
/// server slow to set up, that capped Relay's notification fan-out at about
/// 58 messages a second, 357 ms each against 1.2 ms on a reused connection
/// (Relay #39).
///
/// Errors are classified for the queue. A 5xx reply to the sender, a
/// recipient or the message is `MailError.permanent`, and the job is
/// discarded. Everything else is transient and retried: 4xx replies, broken
/// connections, timeouts, and also authentication and TLS failures. Those
/// are configuration mistakes, and mail queued while one is being fixed
/// should still go out once it is.
public struct SMTPMailTransport: MailTransport {
    public let settings: SMTPSettings
    let logger: Logger
    let pool: SMTPConnectionPool?

    public init(settings: SMTPSettings, logger: Logger = Logger(label: "alula.mail.smtp")) {
        self.init(settings: settings, logger: logger, pool: nil)
    }

    init(settings: SMTPSettings, logger: Logger, pool: SMTPConnectionPool?) {
        self.settings = settings
        self.logger = logger
        self.pool = pool
    }

    /// Delivers `message` in one SMTP transaction: `MAIL FROM`, a `RCPT TO`
    /// for every recipient, then `DATA`.
    ///
    /// All recipients or none, as far as this client controls it: a refusal
    /// of any one recipient ends the transaction before `DATA`, so nobody
    /// gets the message, and a 5xx there makes the whole message
    /// `MailError.permanent` (a queued job is discarded for every
    /// recipient). An address that is not ASCII, to a server without
    /// SMTPUTF8, is permanent too. The message counts as sent only on the
    /// `250` after the body; if the connection breaks or the timeout fires
    /// after the body went out, the error is transient though the server
    /// may have accepted it, so a retry can send a second copy.
    ///
    /// Throws only `MailError`: `invalidMessage` before connecting,
    /// otherwise `permanent` or `transient` as the type's overview describes.
    public func send(_ message: MailMessage) async throws {
        try message.validate()
        let data = try MIMERenderer.render(message, messageIDDomain: settings.messageIDDomain)
        if let pool, try await pool.submit(message, data) { return }
        let timeout = settings.timeout
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await SMTPSession.withConnection(settings: settings, logger: logger) { connection in
                        try await connection.transaction(message, data)
                    }
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw MailError.transient("SMTP session exceeded \(timeout)")
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } catch let refused as SMTPRefused {
            throw refused.error
        } catch let error as MailError {
            throw error
        } catch {
            throw MailError.transient("SMTP: \(error)")
        }
    }

    /// A line starting with "." gets a second one, and the message ends with
    /// the `CRLF . CRLF` terminator (RFC 5321 §4.5.2).
    static func dotStuffed(_ data: Data) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(data.count + 16)
        var atLineStart = true
        for byte in data {
            if atLineStart, byte == UInt8(ascii: ".") { output.append(byte) }
            output.append(byte)
            atLineStart = byte == UInt8(ascii: "\n")
        }
        if !atLineStart { output += Array("\r\n".utf8) }
        output += Array(".\r\n".utf8)
        return output
    }
}

/// The server answered, and the answer was no. The connection is still in a
/// known state, so a pooled connection carries on after `RSET`.
struct SMTPRefused: Error {
    let error: MailError
}

/// Opens connections: TCP, TLS, `EHLO`, `AUTH`.
enum SMTPSession {
    static func withConnection<T>(
        settings: SMTPSettings, logger: Logger,
        _ body: (SMTPConnection) async throws -> T
    ) async throws -> T {
        var configuration = TLSConfiguration.makeClientConfiguration()
        if !settings.verifyCertificates { configuration.certificateVerification = .none }
        let context = try NIOSSLContext(configuration: configuration)
        // SNI takes names, never address literals.
        let hostname =
            settings.host.contains(":") || settings.host.allSatisfy { $0.isNumber || $0 == "." }
            ? nil : settings.host
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(10))
            .connect(host: settings.host, port: settings.port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    if settings.security == .implicitTLS {
                        try channel.pipeline.syncOperations.addHandler(
                            NIOSSLClientHandler(context: context, serverHostname: hostname))
                    }
                    return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                        wrappingChannelSynchronously: channel)
                }
            }
        return try await channel.executeThenClose { inbound, outbound in
            let connection = SMTPConnection(
                settings: settings, raw: channel.channel, inbound: inbound.makeAsyncIterator(),
                outbound: outbound)
            // A server that accepts the connection and never greets would
            // otherwise hold it — and a pooled worker — forever.
            try await withDeadline(settings.timeout, closing: channel.channel) {
                try await connection.open(context: context, hostname: hostname)
            }
            let result = try await body(connection)
            await connection.quit()
            return result
        }
    }
}

extension SMTPSession {
    /// Runs `body`, closing `channel` if it outlasts `timeout` — the only way
    /// to abandon a read the server never answers.
    static func withDeadline<T>(
        _ timeout: Duration, closing channel: any Channel, _ body: () async throws -> T
    ) async throws -> T {
        let fired = Atomic(false)
        let timer = Task {
            try await Task.sleep(for: timeout)
            fired.store(true, ordering: .relaxed)
            channel.close(promise: nil)
        }
        defer { timer.cancel() }
        do {
            return try await body()
        } catch {
            if fired.load(ordering: .relaxed) {
                throw MailError.transient("SMTP exchange exceeded \(timeout)")
            }
            throw error
        }
    }
}

/// One open, authenticated SMTP connection. Used by one task at a time.
final class SMTPConnection {
    let settings: SMTPSettings
    let raw: any Channel
    private var replies: SMTPReplyReader
    private let outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
    private var capabilities: SMTPCapabilities?

    init(
        settings: SMTPSettings, raw: any Channel,
        inbound: NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator,
        outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
    ) {
        self.settings = settings
        self.raw = raw
        self.replies = SMTPReplyReader(inbound)
        self.outbound = outbound
    }

    func say(_ line: String) async throws {
        try await outbound.write(ByteBuffer(string: line + "\r\n"))
    }

    func expect(_ codes: Set<Int>, after step: String, permanentOn5xx: Bool = false) async throws
        -> SMTPReply
    {
        let reply = try await replies.next()
        guard codes.contains(reply.code) else {
            let detail = "\(step) answered \(reply.code) \(reply.lines.joined(separator: " "))"
            throw SMTPRefused(
                error: permanentOn5xx && reply.code >= 500
                    ? MailError.permanent(detail) : MailError.transient(detail))
        }
        return reply
    }

    /// Greeting, `EHLO`, `STARTTLS` if asked for, `AUTH` if configured.
    func open(context: NIOSSLContext, hostname: String?) async throws {
        _ = try await expect([220], after: "greeting")
        try await say("EHLO \(settings.heloName)")
        var capabilities = SMTPCapabilities(try await expect([250], after: "EHLO"))

        if settings.security == .startTLS {
            guard capabilities.startTLS else {
                throw MailError.transient(
                    "\(settings.host) does not offer STARTTLS; refusing to continue in plaintext")
            }
            try await say("STARTTLS")
            _ = try await expect([220], after: "STARTTLS")
            // Built on the event loop: the handler is not Sendable, so it
            // cannot be made here and handed across.
            let raw = self.raw
            try await raw.eventLoop.submit {
                try raw.pipeline.syncOperations.addHandler(
                    NIOSSLClientHandler(context: context, serverHostname: hostname),
                    position: .first)
            }.get()
            try await say("EHLO \(settings.heloName)")
            capabilities = SMTPCapabilities(try await expect([250], after: "EHLO after STARTTLS"))
        }

        if let username = settings.username {
            // Enforced here, where the password would go out, and not only
            // in `init(configuration:)`: settings built in code never pass
            // through that check.
            guard settings.security != .none || settings.allowPlaintextAuth else {
                throw MailError.transient(
                    "refusing to send SMTP credentials over an unencrypted connection; "
                        + "use security starttls or tls, or set allowPlaintextAuth for a local relay")
            }
            let password = settings.password ?? ""
            if capabilities.auth.contains("PLAIN") || !capabilities.auth.contains("LOGIN") {
                let token = Data("\0\(username)\0\(password)".utf8).base64EncodedString()
                try await say("AUTH PLAIN \(token)")
                _ = try await expect([235], after: "AUTH PLAIN")
            } else {
                try await say("AUTH LOGIN")
                _ = try await expect([334], after: "AUTH LOGIN")
                try await say(Data(username.utf8).base64EncodedString())
                _ = try await expect([334], after: "AUTH LOGIN username")
                try await say(Data(password.utf8).base64EncodedString())
                _ = try await expect([235], after: "AUTH LOGIN password")
            }
        }
        self.capabilities = capabilities
    }

    /// `MAIL`, every `RCPT`, `DATA`.
    func transaction(_ message: MailMessage, _ data: Data) async throws {
        let sender = try message.from.unwrap()
        let needsUTF8 = !([sender] + message.recipients).allSatisfy {
            $0.address.unicodeScalars.allSatisfy(\.isASCII)
        }
        if needsUTF8, capabilities?.smtpUTF8 != true {
            throw SMTPRefused(
                error: MailError.permanent(
                    "an address is not ASCII and \(settings.host) does not offer SMTPUTF8"))
        }
        try await say("MAIL FROM:<\(sender.address)>\(needsUTF8 ? " SMTPUTF8" : "")")
        _ = try await expect([250], after: "MAIL FROM", permanentOn5xx: true)
        for recipient in message.recipients {
            try await say("RCPT TO:<\(recipient.address)>")
            _ = try await expect(
                [250, 251], after: "RCPT TO \(recipient.address)", permanentOn5xx: true)
        }
        try await say("DATA")
        _ = try await expect([354], after: "DATA")
        try await outbound.write(ByteBuffer(bytes: SMTPMailTransport.dotStuffed(data)))
        _ = try await expect([250], after: "message", permanentOn5xx: true)
    }

    /// Ends whatever the last transaction left, before the next one.
    func reset() async throws {
        try await say("RSET")
        _ = try await expect([250], after: "RSET")
    }

    func quit() async {
        try? await say("QUIT")
    }
}

struct SMTPReply: Sendable {
    let code: Int
    let lines: [String]
}

struct SMTPCapabilities {
    var startTLS = false
    var smtpUTF8 = false
    var auth: Set<String> = []

    init(_ reply: SMTPReply) {
        for line in reply.lines.dropFirst() {
            let words = line.uppercased().split(separator: " ").map(String.init)
            switch words.first {
            case "STARTTLS": startTLS = true
            case "SMTPUTF8": smtpUTF8 = true
            case "AUTH": auth.formUnion(words.dropFirst())
            default: break
            }
        }
    }
}

/// Reads replies — `NNN-text` continuation lines up to a final `NNN text`.
struct SMTPReplyReader {
    private var iterator: NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator
    private var pending: [UInt8] = []

    init(_ iterator: NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator) {
        self.iterator = iterator
    }

    mutating func next() async throws -> SMTPReply {
        var lines: [String] = []
        while true {
            let line = try await nextLine()
            guard line.count >= 3, let code = Int(line.prefix(3)) else {
                throw MailError.transient("malformed SMTP reply: \(line)")
            }
            lines.append(String(line.dropFirst(4)))
            if line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] == " " {
                return SMTPReply(code: code, lines: lines)
            }
        }
    }

    private mutating func nextLine() async throws -> String {
        while true {
            if let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                var line = Array(pending[..<newline])
                pending.removeSubrange(...newline)
                if line.last == UInt8(ascii: "\r") { line.removeLast() }
                return String(decoding: line, as: UTF8.self)
            }
            guard pending.count < 64 * 1024 else {
                throw MailError.transient("SMTP reply line too long")
            }
            guard var buffer = try await iterator.next() else {
                throw MailError.transient("SMTP server closed the connection")
            }
            pending += buffer.readBytes(length: buffer.readableBytes) ?? []
        }
    }
}

extension Optional where Wrapped == MailAddress {
    fileprivate func unwrap() throws -> MailAddress {
        guard let value = self else { throw MailError.invalidMessage("it has no sender") }
        return value
    }
}

/// Provides an ``SMTPMailTransport`` configured from `mail.smtp.*`, which
/// `AlulaMailModule` takes in place of its development default, and runs its
/// connection pool.
public struct AlulaMailSMTPModule: AlulaModule {
    public let transport: any MailTransport
    let pool: SMTPConnectionPool?

    public init(configuration: Configuration) throws {
        let settings = try SMTPSettings(configuration: configuration)
        let logger = Logger(label: "alula.mail.smtp")
        let pool = settings.poolSize > 0 ? SMTPConnectionPool(settings: settings, logger: logger) : nil
        self.pool = pool
        self.transport = SMTPMailTransport(settings: settings, logger: logger, pool: pool)
    }

    public var service: (any Service)? { pool.map { SMTPPoolService(pool: $0) } }

    /// Stops after the queue worker, whose jobs are what send mail. On
    /// graceful shutdown the pool takes no new messages but sends those
    /// already waiting before it stops; a send after that opens its own
    /// connection. If the pool is cancelled instead, the waiting messages
    /// fail with `MailError.transient`, and queued jobs are retried.
    public var serviceShutdownPhase: ServiceShutdownPhase { .infrastructure }

    public init() {
        preconditionFailure(
            "AlulaMailSMTPModule takes its configuration in init(configuration:), so it cannot be "
                + "instantiated from its type. Pass `composedBy: alulaComposeModules` to Alula.run.")
    }
}

extension SMTPConfigurationError: ModuleConfigurationError {}
