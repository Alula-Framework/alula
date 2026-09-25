import AlulaCore
import AlulaMail
import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL

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
/// ```
public struct SMTPSettings: Sendable, Equatable {
    public enum Security: String, Sendable, Equatable {
        /// Connect in plaintext, then upgrade with `STARTTLS` before anything
        /// else is said. Refuses a server that does not offer it.
        case startTLS = "starttls"
        /// TLS from the first byte (SMTPS, usually port 465).
        case implicitTLS = "tls"
        /// No encryption: a local relay or a test server only.
        case none
    }

    public var host: String
    public var port: Int
    public var security: Security
    public var username: String?
    public var password: String?
    /// The name this client gives in `EHLO`.
    public var heloName: String
    public var timeout: Duration
    /// Off only for a test server with a self-signed certificate.
    public var verifyCertificates: Bool
    /// Credentials over an unencrypted connection. Off unless asked for.
    public var allowPlaintextAuth: Bool
    /// The right-hand side of generated `Message-ID`s.
    public var messageIDDomain: String

    public init(
        host: String, port: Int? = nil, security: Security = .startTLS, username: String? = nil,
        password: String? = nil, heloName: String = "localhost", timeout: Duration = .seconds(30),
        verifyCertificates: Bool = true, allowPlaintextAuth: Bool = false,
        messageIDDomain: String? = nil
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
    }

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
                "mail.smtp.message-id-domain", as: String.self))
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

public struct SMTPConfigurationError: Error, Sendable, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// Sends mail over SMTP (RFC 5321): one connection per message, `STARTTLS`
/// or implicit TLS, `AUTH PLAIN` or `LOGIN`, and SMTPUTF8 when an address
/// needs it.
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

    public init(settings: SMTPSettings, logger: Logger = Logger(label: "alula.mail.smtp")) {
        self.settings = settings
        self.logger = logger
    }

    public func send(_ message: MailMessage) async throws {
        try message.validate()
        let data = try MIMERenderer.render(message, messageIDDomain: settings.messageIDDomain)
        let timeout = settings.timeout
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await session(message, data) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw MailError.transient("SMTP session exceeded \(timeout)")
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } catch let error as MailError {
            throw error
        } catch {
            throw MailError.transient("SMTP: \(error)")
        }
    }

    private func tlsContext() throws -> NIOSSLContext {
        var configuration = TLSConfiguration.makeClientConfiguration()
        if !settings.verifyCertificates { configuration.certificateVerification = .none }
        return try NIOSSLContext(configuration: configuration)
    }

    private var sniHostname: String? {
        // SNI takes names, never address literals.
        settings.host.contains(":") || settings.host.allSatisfy { $0.isNumber || $0 == "." }
            ? nil : settings.host
    }

    private func session(_ message: MailMessage, _ data: Data) async throws {
        let settings = self.settings
        let context = try tlsContext()
        let hostname = sniHostname
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

        try await channel.executeThenClose { inbound, outbound in
            var replies = SMTPReplyReader(inbound.makeAsyncIterator())

            func say(_ line: String) async throws {
                try await outbound.write(ByteBuffer(string: line + "\r\n"))
            }
            func expect(_ codes: Set<Int>, after step: String, permanentOn5xx: Bool = false)
                async throws -> SMTPReply
            {
                let reply = try await replies.next()
                guard codes.contains(reply.code) else {
                    let detail = "\(step) answered \(reply.code) \(reply.lines.joined(separator: " "))"
                    throw permanentOn5xx && reply.code >= 500
                        ? MailError.permanent(detail) : MailError.transient(detail)
                }
                return reply
            }

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
                let raw = channel.channel
                try await raw.eventLoop.submit {
                    try raw.pipeline.syncOperations.addHandler(
                        NIOSSLClientHandler(context: context, serverHostname: hostname),
                        position: .first)
                }.get()
                try await say("EHLO \(settings.heloName)")
                capabilities = SMTPCapabilities(try await expect([250], after: "EHLO after STARTTLS"))
            }

            if let username = settings.username {
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

            let sender = try message.from.unwrap()
            let needsUTF8 = !([sender] + message.recipients).allSatisfy {
                $0.address.unicodeScalars.allSatisfy(\.isASCII)
            }
            if needsUTF8, !capabilities.smtpUTF8 {
                throw MailError.permanent(
                    "an address is not ASCII and \(settings.host) does not offer SMTPUTF8")
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
            try await outbound.write(ByteBuffer(bytes: Self.dotStuffed(data)))
            _ = try await expect([250], after: "message", permanentOn5xx: true)
            try? await say("QUIT")
        }
        logger.debug(
            "mail sent", metadata: ["recipients": "\(message.recipients.count)", "host": "\(settings.host)"])
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
/// `AlulaMailModule` takes in place of its development default.
public struct AlulaMailSMTPModule: AlulaModule {
    public let transport: any MailTransport

    public init(configuration: Configuration) throws {
        self.transport = SMTPMailTransport(settings: try SMTPSettings(configuration: configuration))
    }

    public init() {
        preconditionFailure(
            "AlulaMailSMTPModule takes its configuration in init(configuration:), so it cannot be "
                + "instantiated from its type. Pass `composedBy: alulaComposeModules` to Alula.run.")
    }
}

extension SMTPConfigurationError: ModuleConfigurationError {}
