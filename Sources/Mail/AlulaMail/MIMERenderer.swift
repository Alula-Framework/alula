import Foundation

/// Renders a ``MailMessage`` as the bytes of an RFC 5322 message: headers,
/// MIME structure and transfer encodings, with CRLF line endings throughout.
///
/// A transport that speaks SMTP sends these bytes after `DATA`, and one that
/// calls a provider's "raw message" API sends them as they are. The shape:
///
/// - text only, or HTML only: a single part;
/// - both: `multipart/alternative`, text first, so clients prefer the HTML;
/// - attachments: `multipart/mixed` around the above.
///
/// Bodies are quoted-printable, so any UTF-8 goes through a 7-bit channel.
/// Non-ASCII subjects and display names become RFC 2047 encoded words.
/// Attachments are base64 in 76-character lines.
public enum MIMERenderer {
    public static func render(
        _ message: MailMessage, messageIDDomain: String, date: Date = Date(),
        boundarySeed: String = UUID().uuidString
    ) throws -> Data {
        try message.validate()
        var lines: [String] = []
        lines.append("Date: \(rfc5322Date(date))")
        lines.append("Message-ID: <\(UUID().uuidString.lowercased())@\(messageIDDomain)>")
        if let from = message.from { lines.append("From: \(format(from))") }
        if !message.to.isEmpty { lines.append("To: \(message.to.map(format).joined(separator: ", "))") }
        if !message.cc.isEmpty { lines.append("Cc: \(message.cc.map(format).joined(separator: ", "))") }
        if let replyTo = message.replyTo { lines.append("Reply-To: \(format(replyTo))") }
        lines.append("Subject: \(encodedWord(message.subject))")
        for (name, value) in message.headers.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name): \(value)")
        }
        lines.append("MIME-Version: 1.0")
        lines += body(of: message, seed: boundarySeed)
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    // MARK: Structure

    private static func body(of message: MailMessage, seed: String) -> [String] {
        let content: [String]
        switch (message.text, message.html) {
        case (let text?, let html?):
            let boundary = "alt-\(seed)"
            content =
                ["Content-Type: multipart/alternative; boundary=\"\(boundary)\"", ""]
                + ["--\(boundary)"] + textPart(text, subtype: "plain")
                + ["--\(boundary)"] + textPart(html, subtype: "html")
                + ["--\(boundary)--"]
        case (let text?, nil):
            content = textPart(text, subtype: "plain")
        case (nil, let html?):
            content = textPart(html, subtype: "html")
        case (nil, nil):
            content = textPart("", subtype: "plain")
        }
        guard !message.attachments.isEmpty else { return content }
        let boundary = "mixed-\(seed)"
        var lines = ["Content-Type: multipart/mixed; boundary=\"\(boundary)\"", ""]
        lines += ["--\(boundary)"] + content
        for attachment in message.attachments {
            lines += ["--\(boundary)"] + attachmentPart(attachment)
        }
        lines.append("--\(boundary)--")
        return lines
    }

    private static func textPart(_ text: String, subtype: String) -> [String] {
        [
            "Content-Type: text/\(subtype); charset=utf-8",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            quotedPrintable(text),
        ]
    }

    private static func attachmentPart(_ attachment: MailAttachment) -> [String] {
        let type =
            attachment.contentType.contains(where: { $0.isNewline || $0 == ";" })
            ? "application/octet-stream" : attachment.contentType
        let base64 = attachment.data.base64EncodedString()
        var lines = [
            "Content-Type: \(type)",
            "Content-Transfer-Encoding: base64",
            "Content-Disposition: attachment; \(filenameParameter(attachment.filename))",
            "",
        ]
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 76, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        return lines
    }

    // MARK: Encodings

    /// A display name and address as a header value: the name quoted, or
    /// RFC 2047-encoded when it is not plain ASCII.
    static func format(_ address: MailAddress) -> String {
        guard let name = address.name else { return address.address }
        let plain =
            name.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 32 && $0.value < 127 }
        let rendered =
            plain
            ? "\"" + name.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
            : encodedWord(name)
        return "\(rendered) <\(address.address)>"
    }

    /// RFC 2047 `B` encoding, split so no encoded word exceeds 75 characters
    /// and no UTF-8 sequence is cut in half. ASCII passes through unchanged.
    static func encodedWord(_ text: String) -> String {
        guard !text.unicodeScalars.allSatisfy({ $0.isASCII }) else { return text }
        // 45 bytes → 60 base64 characters, plus 12 of wrapping: 72.
        var words: [String] = []
        var chunk: [UInt8] = []
        for character in text {
            let bytes = Array(String(character).utf8)
            if chunk.count + bytes.count > 45 {
                words.append("=?UTF-8?B?\(Data(chunk).base64EncodedString())?=")
                chunk = []
            }
            chunk += bytes
        }
        if !chunk.isEmpty { words.append("=?UTF-8?B?\(Data(chunk).base64EncodedString())?=") }
        return words.joined(separator: "\r\n ")
    }

    /// RFC 2045 quoted-printable, with CRLF line breaks and soft breaks
    /// keeping every line within 76 characters.
    static func quotedPrintable(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var output: [String] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let bytes = Array(line.utf8)
            var encoded = ""
            var current = ""
            for (index, byte) in bytes.enumerated() {
                let isLast = index == bytes.count - 1
                let token: String
                if (byte == 0x20 || byte == 0x09) && !isLast {
                    token = String(UnicodeScalar(byte))
                } else if byte >= 33 && byte <= 126 && byte != 0x3D {
                    token = String(UnicodeScalar(byte))
                } else {
                    token = String(format: "=%02X", byte)
                }
                if current.count + token.count > 75 {
                    encoded += current + "=\r\n"
                    current = ""
                }
                current += token
            }
            encoded += current
            output.append(encoded)
        }
        return output.joined(separator: "\r\n")
    }

    /// `filename="…"`, or RFC 2231 `filename*=UTF-8''…` when it is not
    /// plain ASCII.
    private static func filenameParameter(_ filename: String) -> String {
        let cleaned = filename.filter { !$0.isNewline && $0 != "\"" && $0 != "\\" }
        if cleaned.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 }) {
            return "filename=\"\(cleaned)\""
        }
        let allowed = CharacterSet.alphanumerics.intersection(
            CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127))
        ).union(CharacterSet(charactersIn: "!#$&+-.^_`|~"))
        let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: allowed) ?? "attachment"
        return "filename*=UTF-8''\(encoded)"
    }

    static func rfc5322Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss '+0000'"
        return formatter.string(from: date)
    }
}
