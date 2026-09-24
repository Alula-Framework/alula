import AlulaCore
import AlulaQueue
import AlulaQueueTesting
import Foundation
import Testing

@testable import AlulaMail
import AlulaMailTesting

private func address(_ text: String, _ name: String? = nil) -> MailAddress {
    try! MailAddress(text, name: name)
}

@Suite("Mail addresses and messages")
struct MailMessageTests {
    @Test("addresses that could inject a header or a recipient are refused")
    func addressValidation() {
        for bad in [
            "no-at-sign", "a@b", "@example.com", "a@", "a b@example.com",
            "a@example.com\r\nBcc: x@evil.com", "a,b@example.com", "<a@example.com>",
            "a@example.com.",
        ] {
            #expect(throws: MailError.self, "\(bad)") { try MailAddress(bad) }
        }
        #expect(throws: MailError.self) { try MailAddress("a@example.com", name: "Ada\r\nBcc: x") }
        #expect((try? MailAddress("ada.lovelace+tag@example.co.uk")) != nil)
    }

    @Test("configuration's address forms parse")
    func parse() throws {
        #expect(try MailAddress.parse("Example <no-reply@example.com>") == address("no-reply@example.com", "Example"))
        #expect(try MailAddress.parse("\"Example, Inc\" <a@example.com>").name == "Example, Inc")
        #expect(try MailAddress.parse(" a@example.com ") == address("a@example.com"))
    }

    @Test("a message that could not be sent as-is is refused before sending")
    func messageValidation() {
        let base = MailMessage(
            from: address("a@example.com"), to: [address("b@example.com")], subject: "Hi",
            text: "Hello")
        #expect((try? base.validate()) != nil)

        var noBody = base
        noBody.text = nil
        #expect(throws: MailError.self) { try noBody.validate() }

        var injected = base
        injected.subject = "Hi\r\nBcc: victim@example.com"
        #expect(throws: MailError.self) { try injected.validate() }

        var reserved = base
        reserved.headers = ["Bcc": "x@example.com"]
        #expect(throws: MailError.self) { try reserved.validate() }

        var headerBreak = base
        headerBreak.headers = ["X-Tag": "a\r\nFrom: evil@example.com"]
        #expect(throws: MailError.self) { try headerBreak.validate() }
    }
}

@Suite("MIME rendering")
struct MIMERenderingTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    func rendered(_ message: MailMessage) throws -> String {
        String(
            decoding: try MIMERenderer.render(
                message, messageIDDomain: "example.com", date: date, boundarySeed: "B"),
            as: UTF8.self)
    }

    @Test("headers, a text body, CRLF everywhere, and no Bcc header")
    func plainText() throws {
        let text = try rendered(
            MailMessage(
                from: address("app@example.com", "Example App"),
                to: [address("ada@example.com")], bcc: [address("hidden@example.com")],
                subject: "Welcome", text: "Hello, Ada."))
        #expect(text.contains("From: \"Example App\" <app@example.com>\r\n"))
        #expect(text.contains("To: ada@example.com\r\n"))
        #expect(text.contains("Subject: Welcome\r\n"))
        #expect(text.contains("Date: Fri, 15 Jan 2027 08:00:00 +0000\r\n"))
        #expect(text.contains("Content-Type: text/plain; charset=utf-8\r\n"))
        #expect(!text.contains("hidden@example.com"))
        #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    @Test("a non-ASCII subject and name become RFC 2047 encoded words")
    func encodedWords() throws {
        let text = try rendered(
            MailMessage(
                from: address("app@example.com", "Zoë"), to: [address("a@example.com")],
                subject: "Café ☕", text: "x"))
        #expect(text.contains("Subject: =?UTF-8?B?\(Data("Café ☕".utf8).base64EncodedString())?=\r\n"))
        #expect(text.contains("From: =?UTF-8?B?\(Data("Zoë".utf8).base64EncodedString())?= <app@example.com>"))
    }

    @Test("quoted-printable: long lines soft-broken within 76, '=' and trailing space encoded")
    func quotedPrintable() {
        let encoded = MIMERenderer.quotedPrintable(String(repeating: "a", count: 200) + "\nx = y \nnaïve")
        for line in encoded.components(separatedBy: "\r\n") { #expect(line.count <= 76) }
        #expect(encoded.contains("x =3D y=20"))
        #expect(encoded.contains("na=C3=AFve"))
        let rejoined = encoded.replacingOccurrences(of: "=\r\n", with: "")
        #expect(rejoined.hasPrefix(String(repeating: "a", count: 200) + "\r\n"))
    }

    @Test("text and HTML become multipart/alternative, text first; attachments wrap it in mixed")
    func multipart() throws {
        let text = try rendered(
            MailMessage(
                from: address("a@example.com"), to: [address("b@example.com")], subject: "S",
                text: "plain", html: "<p>rich</p>",
                attachments: [
                    MailAttachment(filename: "report.pdf", contentType: "application/pdf", data: Data(repeating: 7, count: 100))
                ]))
        let mixed = try #require(text.range(of: "Content-Type: multipart/mixed; boundary=\"mixed-B\""))
        let alternative = try #require(text.range(of: "Content-Type: multipart/alternative; boundary=\"alt-B\""))
        #expect(mixed.lowerBound < alternative.lowerBound)
        let plain = try #require(text.range(of: "text/plain"))
        let html = try #require(text.range(of: "text/html"))
        #expect(plain.lowerBound < html.lowerBound)
        #expect(text.contains("Content-Disposition: attachment; filename=\"report.pdf\""))
        #expect(text.contains(Data(repeating: 7, count: 57).base64EncodedString()))
        #expect(text.hasSuffix("--mixed-B--\r\n"))
    }
}

@Suite("Mailer")
struct MailerTests {
    @Test("the default sender fills in, and send delivers through the transport")
    func sendNow() async throws {
        let transport = RecordingMailTransport()
        let mailer = Mailer(transport: transport, defaultFrom: address("app@example.com"))
        try await mailer.send(MailMessage(to: [address("a@example.com")], subject: "S", text: "t"))
        #expect(transport.sent.first?.from == address("app@example.com"))
    }

    @Test("sendLater validates now, then the worker delivers it")
    func sendLater() async throws {
        let transport = RecordingMailTransport()
        let mailer = Mailer(transport: transport, defaultFrom: address("app@example.com"))
        let harness = QueueTestHarness(handlers: [mailer.deliveryHandler])

        await #expect(throws: MailError.self) {
            try await mailer.sendLater(MailMessage(to: [], subject: "S", text: "t"), via: harness.queue)
        }
        try await mailer.sendLater(
            MailMessage(to: [address("a@example.com")], subject: "Later", text: "t"),
            via: harness.queue)
        #expect(transport.sent.isEmpty)
        #expect(await harness.drain() == [.completed])
        #expect(transport.sent.map(\.subject) == ["Later"])
    }

    @Test("a transient failure retries; a permanent refusal is discarded")
    func failureClasses() async throws {
        let transport = RecordingMailTransport()
        let mailer = Mailer(transport: transport, defaultFrom: address("app@example.com"))
        let harness = QueueTestHarness(handlers: [mailer.deliveryHandler])
        let message = MailMessage(to: [address("a@example.com")], subject: "S", text: "t")

        transport.fail(with: .transient("421 busy"))
        try await mailer.sendLater(message, via: harness.queue)
        guard case .retrying = await harness.drain().first else {
            Issue.record("expected a retry")
            return
        }
        harness.advance(by: .seconds(60))
        #expect(await harness.drain() == [.completed])

        transport.fail(with: .permanent("550 no such user"))
        try await mailer.sendLater(message, via: harness.queue)
        guard case .discarded(let reason) = await harness.drain().first else {
            Issue.record("expected a discard")
            return
        }
        #expect(reason.contains("550"))
    }
}

@Suite("Mail module")
struct MailModuleTests {
    @Test("no transport outside development fails composition; log on purpose is allowed")
    func transportPolicy() throws {
        #expect(throws: MailConfigurationError.self) {
            try AlulaMailModule(
                configuration: Configuration(sources: [TestConfigSource([:])], environment: AlulaEnvironment("prod")))
        }
        #expect(
            (try? AlulaMailModule(
                configuration: Configuration(sources: [TestConfigSource(["mail.transport": "log"])], environment: AlulaEnvironment("prod")))) != nil)
        let dev = try AlulaMailModule(
            configuration: Configuration(sources: [TestConfigSource(["mail.from": "App <app@example.com>"])], environment: .dev))
        #expect(dev.mailer.defaultFrom == address("app@example.com", "App"))
        #expect(dev.mailer.transport is LoggingMailTransport)
    }

    @Test("a provided transport is used in any environment")
    func providedTransport() throws {
        let module = try AlulaMailModule(
            configuration: Configuration(sources: [TestConfigSource([:])], environment: AlulaEnvironment("prod")),
            transport: RecordingMailTransport())
        #expect(module.mailer.transport is RecordingMailTransport)
    }
}
