import Foundation

extension URL {
    /// Whether this URL's host is a loopback name or address: `localhost`
    /// and any `*.localhost` (RFC 6761 §6.3), `127.0.0.1`, and `::1` however
    /// Foundation spells the host — bare or bracketed. Case-insensitive,
    /// since hosts are.
    ///
    /// What "plaintext HTTP is acceptable here" means for a JWKS endpoint
    /// and an APNs endpoint alike. The APNs copy of this check was
    /// case-sensitive and missed both `[::1]` and `*.localhost`.
    package var hostIsLoopback: Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host.hasSuffix(".localhost")
            || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// This URL as it may appear in a log line, a span attribute or an error
    /// message: no query string and no user or password. Query strings carry
    /// tokens often enough that recording them is a leak, and userinfo is a
    /// credential by definition.
    ///
    /// `"unparseable"` when the URL cannot be taken apart — never the raw
    /// string, which would be the one case that leaks everything.
    package var redactedForLog: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return "unparseable"
        }
        components.query = nil
        components.user = nil
        components.password = nil
        return components.string ?? "unparseable"
    }
}

/// `application/x-www-form-urlencoded`, as RFC 6749 and the WHATWG URL
/// standard write it: the unreserved ASCII characters as they are, every
/// other byte of the UTF-8 percent-encoded.
///
/// ASCII is the point. `CharacterSet.alphanumerics` is Unicode letters and
/// digits, so a set built from it leaves `é` or `名` unencoded in a body
/// that must be ASCII.
package enum FormEncoding {
    private static let unreserved: CharacterSet = {
        var set = CharacterSet(charactersIn: "A"..."Z")
        set.insert(charactersIn: "a"..."z")
        set.insert(charactersIn: "0"..."9")
        set.insert(charactersIn: "-._~")
        return set
    }()

    package static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    package static func encode(_ fields: [(String, String)]) -> String {
        fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }

    /// An OAuth client's HTTP Basic credentials (RFC 6749 §2.3.1): each half
    /// form-encoded *before* the pair is joined and base64'd, so a secret
    /// containing `:` or `%` is not misread.
    package static func basicAuthorization(user: String, password: String) -> String {
        "Basic " + Data((encode(user) + ":" + encode(password)).utf8).base64EncodedString()
    }
}
