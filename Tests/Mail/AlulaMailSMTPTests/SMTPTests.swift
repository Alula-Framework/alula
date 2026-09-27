#if SMTP
    import AlulaCore
    import Foundation
    import Logging
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
            let connections = Mutex(0)
        }
        private let record = Record()
        private let serverChannel: any Channel

        var commands: [String] { record.log.withLock { $0 } }
        var data: String { record.body.withLock { $0 } }
        var connections: Int { record.connections.withLock { $0 } }

    /// Whether `QUIT` has arrived, waiting up to two seconds for it. A client
    /// sends `QUIT` and closes without waiting for the `221`, so a send can
    /// return before this server has read it — reading the log at once
    /// raced the connection's last line (it read `DATA` once under load).
    func receivedQuit() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if commands.last == "QUIT" { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return commands.last == "QUIT"
    }

        /// - Parameters:
        ///   - refusing: Recipients answered `550` at `RCPT`.
        ///   - closeAfter: Drop each connection after this many messages, as a
        ///     server enforcing an idle or per-session limit does.
        init(
            capabilities: [String] = ["AUTH PLAIN LOGIN", "SMTPUTF8"],
            replies: [String: String] = [:],
            refusing: Set<String> = [], closeAfter: Int? = nil
        ) async throws {
            let record = self.record
            let caps = capabilities
            let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: 0) { child in
                    child.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                            wrappingChannelSynchronously: child)
                    }
                }
            self.port = channel.channel.localAddress?.port ?? 0
            self.serverChannel = channel.channel
            Task {
                try await channel.executeThenClose { connections in
                    // One task per connection: a pool holds several open at once.
                    try await withThrowingDiscardingTaskGroup { group in
                        for try await connection in connections {
                            record.connections.withLock { $0 += 1 }
                            group.addTask {
                                try? await connection.executeThenClose { inbound, outbound in
                                    func say(_ text: String) async throws {
                                        try await outbound.write(ByteBuffer(string: text + "\r\n"))
                                    }
                                    try await say("220 fake ESMTP")
                                    var pending = ""
                                    var inData = false
                                    var collected = ""
                                    var messages = 0
                                    for try await var buffer in inbound {
                                        pending +=
                                            buffer.readString(length: buffer.readableBytes) ?? ""
                                        while let range = pending.range(of: "\r\n") {
                                            let line = String(pending[..<range.lowerBound])
                                            pending.removeSubrange(..<range.upperBound)
                                            if inData {
                                                if line == "." {
                                                    inData = false
                                                    record.body.withLock { $0 = collected }
                                                    collected = ""
                                                    try await say(replies["."] ?? "250 queued")
                                                    messages += 1
                                                    if let closeAfter, messages >= closeAfter {
                                                        return
                                                    }
                                                } else {
                                                    collected += line + "\r\n"
                                                }
                                                continue
                                            }
                                            record.log.withLock { $0.append(line) }
                                            let verb =
                                                line.split(separator: " ").first.map {
                                                    String($0).uppercased()
                                                } ?? ""
                                            let key =
                                                verb.hasPrefix("MAIL")
                                                ? "MAIL" : verb.hasPrefix("RCPT") ? "RCPT" : verb
                                            if key == "RCPT",
                                                refusing.contains(where: {
                                                    line.contains("<\($0)>")
                                                })
                                            {
                                                try await say("550 no such user")
                                                continue
                                            }
                                            if let scripted = replies[key] {
                                                try await say(scripted)
                                                continue
                                            }
                                            switch key {
                                            case "EHLO":
                                                try await say("250-fake")
                                                for (index, cap) in caps.enumerated() {
                                                    try await say(
                                                        (index == caps.count - 1 ? "250 " : "250-")
                                                            + cap)
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

        @Test(
            "the session: EHLO, AUTH PLAIN, MAIL, every RCPT including bcc, dot-stuffed DATA, QUIT")
        func happyPath() async throws {
            let server = try await FakeSMTPServer()
            defer { Task { await server.stop() } }
            try await transport(server, username: "user").send(message)
            #expect(await server.receivedQuit())

            let commands = server.commands
            #expect(commands.first == "EHLO localhost")
            let token = Data("\0user\0secret".utf8).base64EncodedString()
            #expect(commands.contains("AUTH PLAIN \(token)"))
            #expect(commands.contains("MAIL FROM:<app@example.com>"))
            #expect(commands.contains("RCPT TO:<ada@example.com>"))
            #expect(commands.contains("RCPT TO:<audit@example.com>"))
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
            await #expect(
                throws: MailError.permanent("RCPT TO ada@example.com answered 550 no such user")
            ) {
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
            let stuffed = String(
                decoding: SMTPMailTransport.dotStuffed(Data(".a\r\nb\r\n.\r\n".utf8)), as: UTF8.self
            )
            #expect(stuffed == "..a\r\nb\r\n..\r\n.\r\n")
        }
    }

    /// Against a real server when one is configured — Mailpit in CI:
    /// `docker run -p 1025:1025 -p 8025:8025 -e MP_SMTP_TLS_CERT=sans:localhost
    ///  -e MP_SMTP_TLS_KEY=sans:localhost axllent/mailpit`.
    @Suite("SMTP connection pool", .serialized)
    struct SMTPPoolTests {
        func settings(_ server: FakeSMTPServer, pool: Int = 2, idle: Duration = .seconds(30))
            -> SMTPSettings
        {
            SMTPSettings(
                host: "127.0.0.1", port: server.port, security: .none,
                messageIDDomain: "example.com",
                poolSize: pool, idleTimeout: idle)
        }

        func message(to address: String) -> MailMessage {
            MailMessage(
                from: try! MailAddress("app@example.com"), to: [try! MailAddress(address)],
                subject: "Hello", text: "hi")
        }

        /// Runs a pool for the duration of `body`, then stops it gracefully.
        func withPool(_ settings: SMTPSettings, _ body: (SMTPMailTransport) async throws -> Void)
            async throws
        {
            let pool = SMTPConnectionPool(settings: settings, logger: Logger(label: "test"))
            let running = Task { await pool.run() }
            try await Task.sleep(for: .milliseconds(20))  // run() has opened the queue
            do {
                try await body(
                    SMTPMailTransport(settings: settings, logger: Logger(label: "test"), pool: pool)
                )
            } catch {
                running.cancel()
                throw error
            }
            running.cancel()
            await running.value
        }

        @Test("many messages share a few connections, RSET between them")
        func reusesConnections() async throws {
            // Relay #39: a connection per message capped fan-out at 58 a second.
            let server = try await FakeSMTPServer()
            defer { Task { await server.stop() } }
            try await withPool(settings(server, pool: 2)) { transport in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for index in 0..<20 {
                        group.addTask {
                            try await transport.send(self.message(to: "u\(index)@example.com"))
                        }
                    }
                    try await group.waitForAll()
                }
            }
            #expect(server.connections <= 2)
            #expect(server.commands.filter { $0.hasPrefix("MAIL FROM") }.count == 20)
            #expect(server.commands.filter { $0 == "RSET" }.count >= 18)
        }

        @Test("a refused recipient fails its message only; the connection carries on")
        func refusalKeepsConnection() async throws {
            let server = try await FakeSMTPServer(refusing: ["nobody@example.com"])
            defer { Task { await server.stop() } }
            try await withPool(settings(server, pool: 1)) { transport in
                try await transport.send(message(to: "ada@example.com"))
                await #expect(throws: MailError.self) {
                    try await transport.send(self.message(to: "nobody@example.com"))
                }
                try await transport.send(message(to: "grace@example.com"))
            }
            #expect(server.connections == 1)
            #expect(server.commands.filter { $0.hasPrefix("MAIL FROM") }.count == 3)
        }

        @Test("a connection the server dropped costs a reconnect, not the message")
        func staleConnectionRetried() async throws {
            let server = try await FakeSMTPServer(closeAfter: 1)
            defer { Task { await server.stop() } }
            try await withPool(settings(server, pool: 1)) { transport in
                try await transport.send(message(to: "ada@example.com"))
                try await transport.send(message(to: "grace@example.com"))
            }
            #expect(server.connections == 2)
            #expect(server.commands.filter { $0.hasPrefix("MAIL FROM") }.count == 2)
        }

        @Test("an idle connection is closed with QUIT, and the next message opens another")
        func idleConnectionClosed() async throws {
            let server = try await FakeSMTPServer()
            defer { Task { await server.stop() } }
            try await withPool(settings(server, pool: 1, idle: .milliseconds(150))) { transport in
                try await transport.send(message(to: "ada@example.com"))
                try await Task.sleep(for: .milliseconds(400))
                #expect(await server.receivedQuit())
                try await transport.send(message(to: "grace@example.com"))
            }
            #expect(server.connections == 2)
        }

        @Test("with no pool running, a message gets its own connection, as before")
        func fallsBackWithoutPool() async throws {
            let server = try await FakeSMTPServer()
            defer { Task { await server.stop() } }
            let settings = settings(server)
            let idle = SMTPConnectionPool(settings: settings, logger: Logger(label: "test"))
            let transport = SMTPMailTransport(
                settings: settings, logger: Logger(label: "test"), pool: idle)
            try await transport.send(message(to: "ada@example.com"))
            #expect(server.connections == 1)
            #expect(await server.receivedQuit())
        }

        @Test("pool settings from configuration, and 0 turns the pool off")
        func configuration() throws {
            let values = ["mail.smtp.host": "smtp.example.com"]
            let defaults = try AlulaMailSMTPModule(configuration: Configuration(values: values))
            #expect(defaults.service != nil)
            let off = try AlulaMailSMTPModule(
                configuration: Configuration(
                    values: values.merging(["mail.smtp.pool-size": "0"]) { $1 }))
            #expect(off.service == nil)
            #expect(throws: SMTPConfigurationError.self) {
                try SMTPSettings(
                    configuration: Configuration(
                        values: values.merging(["mail.smtp.idle-seconds": "0"]) { $1 }))
            }
        }
    }

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
                    host: environment["ALULA_SMTP_TEST_HOST"] ?? "localhost", port: port,
                    security: .startTLS, verifyCertificates: false))
            try await transport.send(
                MailMessage(
                    from: try MailAddress("app@example.com", name: "Zoë's App"),
                    to: [try MailAddress("ada@example.com")],
                    subject: "Integration ✓",
                    text: "Sent by the Alula SMTP transport.\n"
                        + String(repeating: "long line ", count: 30)
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

#if SMTP
/// Throughput against a real server, pooled and not. Set
/// ALULA_SMTP_BENCH_PORT (a plaintext SMTP port, e.g. Mailpit's 1025) to run.
@Suite(
    "SMTP throughput", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["ALULA_SMTP_BENCH_PORT"] != nil))
struct SMTPThroughputBenchmark {
    @Test(arguments: [0, 4])
    func throughput(pool: Int) async throws {
        let port = Int(ProcessInfo.processInfo.environment["ALULA_SMTP_BENCH_PORT"]!)!
        let settings = SMTPSettings(
            host: "127.0.0.1", port: port, security: .none, messageIDDomain: "example.com", poolSize: pool)
        let connections = pool > 0 ? SMTPConnectionPool(settings: settings, logger: Logger(label: "bench")) : nil
        let running = connections.map { pool in Task { await pool.run() } }
        try await Task.sleep(for: .milliseconds(20))
        let transport = SMTPMailTransport(settings: settings, logger: Logger(label: "bench"), pool: connections)
        let count = 200
        let started = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Ten at a time, as Relay's queue worker sends.
            var next = 0
            for _ in 0..<10 {
                let index = next
                next += 1
                group.addTask {
                    try await transport.send(
                        MailMessage(
                            from: try MailAddress("bench@example.com"), to: [try MailAddress("u\(index)@example.com")],
                            subject: "bench", text: "hello"))
                }
            }
            while try await group.next() != nil, next < count {
                let index = next
                next += 1
                group.addTask {
                    try await transport.send(
                        MailMessage(
                            from: try MailAddress("bench@example.com"), to: [try MailAddress("u\(index)@example.com")],
                            subject: "bench", text: "hello"))
                }
            }
        }
        let seconds = Double((ContinuousClock.now - started).components.attoseconds) / 1e18
            + Double((ContinuousClock.now - started).components.seconds)
        print("SMTP-BENCH pool=\(pool) messages=\(count) seconds=\(String(format: "%.2f", seconds)) rate=\(String(format: "%.0f", Double(count) / seconds))/s")
        running?.cancel()
        await running?.value
    }
}
#endif
