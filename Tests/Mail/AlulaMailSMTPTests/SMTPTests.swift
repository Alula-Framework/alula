#if SMTP
import AlulaCore
import Foundation
import NIOCore
import NIOPosix
import Synchronization
import Testing

import AlulaMail
@testable import AlulaMailSMTP

/// A scripted SMTP server: answers each command from `replies` (by verb),
/// records what it was told, and collects the message after DATA.
final class FakeSMTPServer: Sendable {
    let port: Int
    final class Record: Sendable {
        let log = Mutex<[String]>([])
        let body = Mutex<String>("")
    }
    private let record = Record()
    private let serverChannel: any Channel

    var commands: [String] { record.log.withLock { $0 } }
    var data: String { record.body.withLock { $0 } }

    init(capabilities: [String] = ["AUTH PLAIN LOGIN", "SMTPUTF8"], replies: [String: String] = [:])
        async throws
    {
        let record = self.record
        let caps = capabilities
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0) { child in
                child.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: child)
                }
            }
        self.port = channel.channel.localAddress?.port ?? 0
        self.serverChannel = channel.channel
        Task {
            try await channel.executeThenClose { connections in
                for try await connection in connections {
                    try? await connection.executeThenClose { inbound, outbound in
                        func say(_ text: String) async throws {
                            try await outbound.write(ByteBuffer(string: text + "\r\n"))
                        }
                        try await say("220 fake ESMTP")
                        var pending = ""
                        var inData = false
                        var collected = ""
                        for try await var buffer in inbound {
                            pending += buffer.readString(length: buffer.readableBytes) ?? ""
                            while let range = pending.range(of: "\r\n") {
                                let line = String(pending[..<range.lowerBound])
                                pending.removeSubrange(..<range.upperBound)
                                if inData {
                                    if line == "." {
                                        inData = false
                                        record.body.withLock { $0 = collected }
                                        try await say(replies["."] ?? "250 queued")
                                    } else {
                                        collected += line + "\r\n"
                                    }
                                    continue
                                }
                                record.log.withLock { $0.append(line) }
                                let verb = line.split(separator: " ").first.map { String($0).uppercased() } ?? ""
                                let key = verb.hasPrefix("MAIL") ? "MAIL" : verb.hasPrefix("RCPT") ? "RCPT" : verb
                                if let scripted = replies[key] {
                                    try await say(scripted)
                                    continue
                                }
                                switch key {
                                case "EHLO":
                                    try await say("250-fake")
                                    for (index, cap) in caps.enumerated() {
                                        try await say((index == caps.count - 1 ? "250 " : "250-") + cap)
                                    }
                                    if caps.isEmpty { try await say("250 ok") }
                                case "AUTH": try await say("235 ok")
                                case "DATA":
                                    inData = true
                                    try await say("354 go")
                                case "QUIT":
                                    try await say("221 bye")
                                    return
                                default: try await say("250 ok")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func stop() async { try? await serverChannel.close() }
}

@Suite("SMTP transport", .serialized)
struct SMTPTests {
    func transport(_ server: FakeSMTPServer, username: String? = nil) -> SMTPMailTransport {
        SMTPMailTransport(
            settings: SMTPSettings(
                host: "127.0.0.1", port: server.port, security: .none, username: username,
                password: "secret", allowPlaintextAuth: true, messageIDDomain: "example.com"))
    }

    let message = MailMessage(
        from: try! MailAddress("app@example.com"),
        to: [try! MailAddress("ada@example.com")], bcc: [try! MailAddress("audit@example.com")],
        subject: "Hello", text: "line one\n.hidden dot line\nend")

    @Test("the session: EHLO, AUTH PLAIN, MAIL, every RCPT including bcc, dot-stuffed DATA, QUIT")
    func happyPath() async throws {
        let server = try await FakeSMTPServer()
        defer { Task { await server.stop() } }
        try await transport(server, username: "user").send(message)

        let commands = server.commands
        #expect(commands.first == "EHLO localhost")
        let token = Data("\0user\0secret".utf8).base64EncodedString()
        #expect(commands.contains("AUTH PLAIN \(token)"))
        #expect(commands.contains("MAIL FROM:<app@example.com>"))
        #expect(commands.contains("RCPT TO:<ada@example.com>"))
        #expect(commands.contains("RCPT TO:<audit@example.com>"))
        #expect(commands.last == "QUIT")
        #expect(server.data.contains("\r\n..hidden dot line\r\n"))
        #expect(server.data.contains("Subject: Hello"))
        #expect(!server.data.contains("audit@example.com"))
    }

    @Test("AUTH LOGIN when that is all the server offers")
    func authLogin() async throws {
        let server = try await FakeSMTPServer(
            capabilities: ["AUTH LOGIN"], replies: ["AUTH": "334 VXNlcm5hbWU6"])
        defer { Task { await server.stop() } }
        // The fake answers 334 to every AUTH-prefixed line, so the exchange
        // stalls at the last step; what matters is which mechanism was chosen.
        _ = try? await transport(server, username: "user").send(message)
        #expect(server.commands.contains("AUTH LOGIN"))
    }

    @Test("a 5xx refusal of a recipient is permanent; a 4xx is transient")
    func classification() async throws {
        let refusing = try await FakeSMTPServer(replies: ["RCPT": "550 no such user"])
        defer { Task { await refusing.stop() } }
        await #expect(throws: MailError.permanent("RCPT TO ada@example.com answered 550 no such user")) {
            try await transport(refusing).send(message)
        }

        let busy = try await FakeSMTPServer(replies: ["MAIL": "421 try later"])
        defer { Task { await busy.stop() } }
        do {
            try await transport(busy).send(message)
            Issue.record("expected a failure")
        } catch MailError.transient(let reason) {
            #expect(reason.contains("421"))
        }
    }

    @Test("STARTTLS is required when asked for, never silently skipped")
    func startTLSRequired() async throws {
        let server = try await FakeSMTPServer(capabilities: ["AUTH PLAIN"])
        defer { Task { await server.stop() } }
        let transport = SMTPMailTransport(
            settings: SMTPSettings(host: "127.0.0.1", port: server.port, security: .startTLS))
        do {
            try await transport.send(message)
            Issue.record("sent in plaintext")
        } catch MailError.transient(let reason) {
            #expect(reason.contains("STARTTLS"))
        }
        #expect(!server.commands.contains { $0.hasPrefix("MAIL") })
    }

    @Test("credentials over plaintext are refused at configuration")
    func plaintextAuthRefused() {
        #expect(throws: SMTPConfigurationError.self) {
            try SMTPSettings(
                configuration: Configuration(values: [
                    "mail.smtp.host": "relay.local", "mail.smtp.security": "none",
                    "mail.smtp.username": "u",
                ]))
        }
    }

    @Test("dot-stuffing and the terminator")
    func dotStuffing() {
        let stuffed = String(decoding: SMTPMailTransport.dotStuffed(Data(".a\r\nb\r\n.\r\n".utf8)), as: UTF8.self)
        #expect(stuffed == "..a\r\nb\r\n..\r\n.\r\n")
    }
}

/// Against a real server when one is configured — Mailpit in CI:
/// `docker run -p 1025:1025 -p 8025:8025 -e MP_SMTP_TLS_CERT=sans:localhost
///  -e MP_SMTP_TLS_KEY=sans:localhost axllent/mailpit`.
@Suite(
    "SMTP against a real server", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["ALULA_SMTP_TEST_PORT"] != nil))
struct SMTPIntegrationTests {
    @Test("STARTTLS delivery to a real server")
    func realServer() async throws {
        let environment = ProcessInfo.processInfo.environment
        let port = Int(environment["ALULA_SMTP_TEST_PORT"]!)!
        let transport = SMTPMailTransport(
            settings: SMTPSettings(
                host: environment["ALULA_SMTP_TEST_HOST"] ?? "localhost", port: port, security: .startTLS, verifyCertificates: false))
        try await transport.send(
            MailMessage(
                from: try MailAddress("app@example.com", name: "Zoë's App"),
                to: [try MailAddress("ada@example.com")],
                subject: "Integration ✓",
                text: "Sent by the Alula SMTP transport.\n" + String(repeating: "long line ", count: 30)
                    + "\n.a line that starts with a dot",
                html: "<p>Sent by the <b>Alula</b> SMTP transport.</p>",
                attachments: [
                    MailAttachment(
                        filename: "résumé.txt", contentType: "text/plain",
                        data: Data("attached ✓".utf8))
                ]))
    }
}
#endif
