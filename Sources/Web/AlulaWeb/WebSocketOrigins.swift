import AlulaCore
import Foundation
import HTTPTypes

/// Which pages may open a WebSocket to this service.
///
/// A WebSocket handshake is a `GET`, so CSRF protection exempts it, and CORS
/// does not apply to WebSockets at all: a browser opens a socket to any origin
/// and sends that origin's cookies along. A socket authenticated from the
/// session cookie is therefore open to any page the user visits — cross-site
/// WebSocket hijacking — unless the server checks `Origin` itself. Browsers
/// always send `Origin` on a WebSocket handshake, and a page cannot forge it.
///
/// The default is **same origin**: the `Origin` must name the host the request
/// was addressed to. A request with no `Origin` is allowed, because it did not
/// come from a browser page, and those are the only callers that carry someone
/// else's cookies.
///
/// ```yaml
/// web:
///   websocket:
///     allowed-origins: https://app.example.com, https://admin.example.com
///     # or "*" to turn the check off — only for sockets that never read a cookie
/// ```
///
/// Behind a reverse proxy that rewrites `Host`, same-origin is decided by
/// `X-Forwarded-Host` when the proxy is in `web.trusted-proxies`; otherwise
/// list the public origin in `allowed-origins`.
public struct WebSocketOrigins: Sendable {
    let allowsAnyOrigin: Bool
    let additional: AllowedOrigins?

    /// Same origin only.
    public static let sameOrigin = WebSocketOrigins(allowsAnyOrigin: false, additional: nil)

    /// Same origin, plus `allowed`.
    public static func sameOrigin(or allowed: AllowedOrigins) -> WebSocketOrigins {
        WebSocketOrigins(allowsAnyOrigin: false, additional: allowed)
    }

    /// No check. Only for sockets whose authentication never comes from a
    /// cookie — a bearer token in the first frame, say.
    public static let anyOrigin = WebSocketOrigins(allowsAnyOrigin: true, additional: nil)

    init(allowsAnyOrigin: Bool, additional: AllowedOrigins?) {
        self.allowsAnyOrigin = allowsAnyOrigin
        self.additional = additional
    }

    /// Reads `web.websocket.allowed-origins`: a comma-separated list of
    /// origins allowed besides this one, or `*` for no check.
    public init(configuration: Configuration) throws {
        guard
            let raw = try configuration.getIfPresent(
                "web.websocket.allowed-origins", as: String.self)
        else {
            self = .sameOrigin
            return
        }
        let entries = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if entries == ["*"] {
            self = .anyOrigin
        } else if entries.contains("*") {
            throw WebSocketOriginsConfigurationError(value: raw)
        } else {
            self = entries.isEmpty ? .sameOrigin : .sameOrigin(or: .exact(Set(entries)))
        }
    }

    /// Whether this handshake may proceed.
    func permits(_ request: Request, trustedProxies: TrustedProxies) -> Bool {
        guard !allowsAnyOrigin, let origin = request.headers[.origin] else { return true }
        if additional?.allows(origin) == true { return true }
        guard let originAuthority = Self.authority(ofOrigin: origin) else { return false }
        return addressedAuthorities(of: request, trustedProxies: trustedProxies)
            .contains { Self.normalized($0, scheme: originAuthority.scheme) == originAuthority.value }
    }

    private func addressedAuthorities(
        of request: Request, trustedProxies: TrustedProxies
    ) -> [String] {
        var authorities = [request.head.authority].compactMap { $0 }
        if let peer = request.remoteAddress, trustedProxies.isTrusted(peer),
            let forwarded = request.headers[HTTPField.Name("X-Forwarded-Host")!]
        {
            // The hop closest to us appended last.
            if let last = forwarded.split(separator: ",").last {
                authorities.append(last.trimmingCharacters(in: .whitespaces))
            }
        }
        return authorities
    }

    /// `https://Example.com:443` → (`https`, `example.com`). `null` and
    /// anything without a scheme are not origins a page can be same-origin
    /// with.
    static func authority(ofOrigin origin: String) -> (scheme: String, value: String)? {
        guard let separator = origin.range(of: "://") else { return nil }
        let scheme = origin[..<separator.lowerBound].lowercased()
        let rest = origin[separator.upperBound...]
        guard !rest.isEmpty, !rest.contains("/") else { return nil }
        return (scheme, normalized(String(rest), scheme: scheme))
    }

    /// Lowercased, with the scheme's default port dropped — `Host` and
    /// `Origin` both omit it normally, but either may spell it out.
    static func normalized(_ authority: String, scheme: String) -> String {
        let lowered = authority.lowercased()
        let defaultPort = (scheme == "https" || scheme == "wss") ? ":443" : ":80"
        return lowered.hasSuffix(defaultPort)
            ? String(lowered.dropLast(defaultPort.count)) : lowered
    }
}

struct WebSocketOriginsConfigurationError: Error, CustomStringConvertible {
    let value: String
    var description: String {
        "web.websocket.allowed-origins mixes \"*\" with named origins (\(value)). "
            + "Use \"*\" alone to turn the check off, or list origins."
    }
}
