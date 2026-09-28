extension Request {
    /// RFC 7235 credentials syntax: `Bearer 1*SP token68`.
    ///
    /// The one parser for a bearer credential: `Request.bearerToken` in
    /// AlulaSecurityCore authenticates with it, and ``CSRFProtection`` exempts
    /// with it. When the two parsed separately they disagreed on
    /// `Bearer a b` — CSRF saw a bearer token and skipped its check, while
    /// authentication saw none and fell back to the session cookie, so a
    /// cookie-authenticated request went through unchecked.
    package static func parseBearer(_ headerValue: String) -> String? {
        // `trimmingCharacters(in: .whitespaces)` is the only thing this file
        // wanted Foundation for, on the path every authenticated request
        // takes. Two `drop`s off the stdlib do the same job.
        var trimmed = Substring(headerValue)
        while let first = trimmed.first, first.isWhitespace { trimmed.removeFirst() }
        while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
        guard trimmed.count > 7 else { return nil }
        let schemeEnd = trimmed.index(trimmed.startIndex, offsetBy: 6)
        guard trimmed[..<schemeEnd].lowercased() == "bearer" else { return nil }
        let afterScheme = trimmed[schemeEnd...]
        // At least one space must separate scheme and credentials.
        guard afterScheme.first == " " else { return nil }
        let token = afterScheme.drop(while: { $0 == " " })
        guard !token.isEmpty, !token.contains(where: \.isWhitespace) else { return nil }
        return String(token)
    }
}
