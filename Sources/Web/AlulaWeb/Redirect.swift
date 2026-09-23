import Foundation
import HTTPTypes

// Redirects.
//
// A redirect is a status and a `Location`, which is small enough that every
// framework offers it and most offer it badly: `redirect(to:)` with a default
// nobody reads, or a raw status parameter that accepts `200`. The choice
// between the five codes is the whole of the feature — 303 and 307 differ on
// whether the follow-up repeats the POST, and getting that wrong is either a
// double charge or a login that drops the form.
//
// So the status is an enum whose cases say what they do, and each one carries
// the reason to pick it.

extension Response {
    /// Which redirect, said in terms of what the client does next.
    ///
    /// The two legacy codes are here because real clients send them and a
    /// proxy in front may require them, not because they are good choices.
    public enum Redirect: Sendable, Equatable {
        /// `303 See Other` — the follow-up is a **GET**, whatever this request
        /// was. The one a form POST wants: the browser lands on a page it can
        /// reload without re-submitting.
        case seeOther

        /// `307 Temporary Redirect` — the follow-up repeats **this** method
        /// and body. Right for moving a POST endpoint; wrong after handling
        /// one, because the client will send it again.
        case temporary

        /// `308 Permanent Redirect` — 307, and cacheable. The client may stop
        /// asking the old location, so be sure before shipping it.
        case permanent

        /// `302 Found` — nominally "repeat the method", but browsers have
        /// turned POST into GET here since Netscape, so it means 303 in
        /// practice and says so in neither direction. Prefer ``seeOther``.
        case found

        /// `301 Moved Permanently` — ``found``'s caveat plus permanence, and
        /// the permanence is the kind clients cache hard. Prefer ``permanent``.
        case movedPermanently

        public var status: HTTPResponse.Status {
            switch self {
            case .seeOther: return .seeOther
            case .temporary: return .temporaryRedirect
            case .permanent: return .permanentRedirect
            case .found: return .found
            case .movedPermanently: return .movedPermanently
            }
        }
    }

    /// A redirect to `location`, defaulting to the 303 that makes a form POST
    /// survive a reload.
    ///
    /// ```swift
    /// return .redirect(to: "/projects/\(project.id)")            // after a POST
    /// return .redirect(to: "/v2/reports", .permanent)            // a moved endpoint
    /// ```
    ///
    /// The body is empty. RFC 9110 lets a 3xx carry one and no browser shows
    /// it, so there is nothing to put there that anyone would read.
    public static func redirect(to location: String, _ kind: Redirect = .seeOther) -> Response {
        var headers: HTTPFields = [:]
        headers[.location] = location
        return .fixed(status: kind.status, headers: headers, body: Data())
    }
}

extension RequestContext {
    /// This request's path and query, percent-encoded to sit inside a query
    /// value — the `next` of a login redirect.
    ///
    /// ```swift
    /// return .redirect(to: "/login?next=\(context.returnTo)")
    /// ```
    ///
    /// Encoded with `&`, `=`, `?` and `+` excluded, which `.urlQueryAllowed`
    /// permits and which is exactly what breaks this: a return path of
    /// `/search?q=a&b=c` written raw ends the `next` parameter early, and the
    /// caller comes back to `/search?q=a` having lost half the query.
    public var returnTo: String {
        let query = request.rawQuery
        let target = query.isEmpty ? request.path : "\(request.path)?\(query)"
        return target.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed)
            ?? target
    }

    /// `.urlQueryAllowed` minus the delimiters that would end the value.
    private static let queryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+#")
        return allowed
    }()
}
