import Foundation

/// An email address, optionally with a display name.
///
/// Validated when made, and deliberately stricter than RFC 5322: no quoted
/// local parts, no comments, no whitespace, no line breaks anywhere. Every
/// character that could end a header early or add a recipient is refused
/// here, so no address can smuggle a header into a message.
public struct MailAddress: Sendable, Hashable, Codable, CustomStringConvertible {
    /// `local@domain`, as given. A non-ASCII address is kept; the SMTP
    /// transport needs the server's SMTPUTF8 to send to it.
    public let address: String
    /// The display name, or nil. An empty name is stored as nil.
    public let name: String?

    /// Validates `address` and `name`.
    ///
    /// - Throws: ``MailError/invalidAddress(_:)`` for anything but one `@`
    ///   between a non-empty local part and a dotted domain, for whitespace
    ///   or any of `<>,;:"()[]\`, or for a line break in `name`.
    public init(_ address: String, name: String? = nil) throws {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        let forbidden = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "<>,;:\"()[]\\"))
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
            parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
            address.unicodeScalars.allSatisfy({ !forbidden.contains($0) })
        else { throw MailError.invalidAddress(address) }
        if let name, name.contains(where: \.isNewline) {
            throw MailError.invalidAddress(address)
        }
        self.address = address
        self.name = name.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// As a header writes it: `Name <address>`, the name encoded when it
    /// needs to be, or the bare address.
    public var description: String { MIMERenderer.format(self) }

    /// Whether the address needs SMTPUTF8 to be sent as written.
    var isASCII: Bool { address.unicodeScalars.allSatisfy(\.isASCII) }

    /// Decodes and validates again, so a queued message cannot carry an
    /// address the initializer would refuse.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            try container.decode(String.self, forKey: .address),
            name: try container.decodeIfPresent(String.self, forKey: .name))
    }
}

/// A file carried by a message.
public struct MailAttachment: Sendable, Hashable, Codable {
    /// The name the recipient sees.
    public var filename: String
    /// A MIME type such as `application/pdf`.
    public var contentType: String
    /// The file's bytes, base64-encoded when rendered. They ride the job
    /// queue inside the message, so keep queued attachments small.
    public var data: Data

    /// An attachment.
    public init(filename: String, contentType: String, data: Data) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }
}

/// One email. `Codable`, so it can ride the job queue to be sent later.
///
/// ```swift
/// try await mailer.send(
///     MailMessage(
///         to: [try MailAddress("ada@example.com", name: "Ada")],
///         subject: "Reset your password",
///         text: "Follow this link within an hour: \(link)"))
/// ```
///
/// `from` may be left out: the ``Mailer`` fills in `mail.from`.
public struct MailMessage: Sendable, Hashable, Codable {
    /// The sender. Nil takes the ``Mailer``'s `mail.from`; nil with no
    /// default fails validation.
    public var from: MailAddress?
    /// Primary recipients, in the `To` header.
    public var to: [MailAddress]
    /// Copied recipients, in the `Cc` header.
    public var cc: [MailAddress]
    /// Receives the message; never appears in its headers.
    public var bcc: [MailAddress]
    /// Where replies go, when not to `from`.
    public var replyTo: MailAddress?
    /// The subject line. May not contain a line break; non-ASCII is encoded.
    public var subject: String
    /// The plain-text body. Send one: spam filters and screen readers both
    /// read it, and some clients show nothing else.
    public var text: String?
    /// The HTML body, sent beside `text` as an alternative when both are set.
    public var html: String?
    /// Extra headers. Names are checked; values may not contain line breaks.
    public var headers: [String: String]
    /// Files carried by the message.
    public var attachments: [MailAttachment]

    /// A message. Nothing is checked until ``validate()``, which
    /// ``Mailer`` calls before sending or enqueueing.
    public init(
        from: MailAddress? = nil, to: [MailAddress], cc: [MailAddress] = [],
        bcc: [MailAddress] = [], replyTo: MailAddress? = nil, subject: String,
        text: String? = nil, html: String? = nil, headers: [String: String] = [:],
        attachments: [MailAttachment] = []
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.subject = subject
        self.text = text
        self.html = html
        self.headers = headers
        self.attachments = attachments
    }

    /// Everyone the message is delivered to: `to`, `cc` and `bcc`.
    public var recipients: [MailAddress] { to + cc + bcc }

    /// Refuses a message that cannot be sent as-is: no sender, no
    /// recipients, no body, or a line break where one would start a header.
    /// Also refuses a custom header whose name is not a plain token or is
    /// one the renderer writes itself (`From`, `Bcc`, `Content-Type`, …).
    ///
    /// - Throws: ``MailError/invalidMessage(_:)``.
    public func validate() throws {
        guard from != nil else { throw MailError.invalidMessage("it has no sender") }
        guard !recipients.isEmpty else { throw MailError.invalidMessage("it has no recipients") }
        guard text != nil || html != nil else {
            throw MailError.invalidMessage("it has neither a text nor an HTML body")
        }
        guard !subject.contains(where: \.isNewline) else {
            throw MailError.invalidMessage("the subject contains a line break")
        }
        let reserved: Set<String> = [
            "from", "to", "cc", "bcc", "reply-to", "subject", "date", "message-id",
            "mime-version", "content-type", "content-transfer-encoding",
        ]
        for (name, value) in headers {
            let isToken =
                !name.isEmpty
                && name.unicodeScalars.allSatisfy {
                    $0.isASCII && $0.value > 32 && $0.value < 127 && $0 != ":"
                }
            guard isToken, !reserved.contains(name.lowercased()) else {
                throw MailError.invalidMessage("\"\(name)\" is not a header this message may set")
            }
            guard !value.contains(where: \.isNewline) else {
                throw MailError.invalidMessage("header \(name) contains a line break")
            }
        }
    }
}

/// Why a message was not sent. The first two are the caller's mistake and
/// are found before anything is sent; the last two come from delivery.
public enum MailError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A ``MailAddress`` refused the text it was given.
    case invalidAddress(String)
    /// ``MailMessage/validate()`` refused the message. A queued job failing
    /// this way is discarded, not retried.
    case invalidMessage(String)
    /// Refused for good: a bad address, a policy rejection. Retrying will not help.
    case permanent(String)
    /// Refused for now: a busy server, a dropped connection. Retrying may help.
    case transient(String)

    /// Whether sending again may succeed: only a transient failure. A job
    /// that sends mail itself retries on this and records the rest.
    public var isRetryable: Bool {
        if case .transient = self { return true }
        return false
    }

    /// Which of the four, and the reason.
    public var description: String {
        switch self {
        case .invalidAddress(let address): "not a usable email address: \(address)"
        case .invalidMessage(let reason): "the message cannot be sent: \(reason)"
        case .permanent(let reason): "delivery refused: \(reason)"
        case .transient(let reason): "delivery failed, may succeed later: \(reason)"
        }
    }
}
