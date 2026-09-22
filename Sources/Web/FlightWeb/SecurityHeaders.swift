import FlightCore
import Foundation
import HTTPTypes

/// The response headers that tell a browser to be stricter than it would be
/// by default: don't sniff content types, don't let other sites frame this
/// one, don't leak full URLs in `Referer`, and, when configured, insist on
/// HTTPS and restrict what a page may load.
///
/// A policy of the web module, not a middleware, and that is the whole point.
/// Dispatch routes first and then runs the matched route's own lanes, so a
/// middleware in `.default` never runs for a route naming
/// `pipelines: [.authenticated]` — `CORS` documents exactly that trap. For
/// CORS a missing header fails loudly in the browser console. For these it
/// fails silently: the page works and is simply less protected, on precisely
/// the signed-in routes that matter most. So Dispatch applies the policy to
/// every response it produces, after every lane, error responses, 404s and
/// static assets included.
///
/// **A header the response already carries is left alone.** A route that
/// means to be framed sets its own `X-Frame-Options` or
/// `Content-Security-Policy`, and that wins over the application-wide
/// default. The policy fills gaps; it never overrides a decision made closer
/// to the response.
///
/// ## Defaults
///
/// Three headers are on unless configured off, because each is correct for
/// nearly every service and wrong only for one that knows it:
///
/// | Header | Default |
/// |---|---|
/// | `X-Content-Type-Options` | `nosniff` |
/// | `X-Frame-Options` | `DENY` |
/// | `Referrer-Policy` | `strict-origin-when-cross-origin` |
///
/// Two are **off** unless configured, because a wrong default is expensive:
///
/// - **`Strict-Transport-Security`** is a promise a browser remembers for
///   `max-age`. Sent by mistake — from a staging host on a shared parent
///   domain with `includeSubDomains`, say — it locks every browser that saw
///   it out of plain HTTP on that domain until the age runs out, and nothing
///   the server does afterwards can recall it. That is an operator's decision.
///   Browsers ignore it over plain HTTP, so it is sent regardless of how this
///   process was reached: behind a TLS-terminating proxy, this process sees
///   HTTP while the browser saw HTTPS.
/// - **`Content-Security-Policy`** depends on what the pages load. There is no
///   default that is both useful and harmless, so there is none.
///
/// ## Configuration
///
/// ```yaml
/// web:
///   security-headers:
///     frame-options: sameorigin          # deny | sameorigin | off
///     referrer-policy: no-referrer       # any policy token, or off
///     content-type-options: nosniff      # nosniff | off
///     hsts-max-age: 31536000s            # absent = no HSTS
///     hsts-include-subdomains: true
///     content-security-policy: "default-src 'self'"
/// ```
///
/// A value this does not recognize fails composition, naming the key, rather
/// than quietly sending nothing.
public struct SecurityHeaders: Sendable, Equatable {

    public enum FrameOptions: String, Sendable, Equatable {
        case deny = "DENY"
        case sameOrigin = "SAMEORIGIN"
    }

    /// HSTS. `preload` asks to be added to browsers' built-in lists, which is
    /// close to permanent; the list's own requirements are checked at
    /// construction.
    public struct StrictTransportSecurity: Sendable, Equatable {
        public var maxAge: Duration
        public var includeSubdomains: Bool
        public var preload: Bool

        public init(maxAge: Duration, includeSubdomains: Bool = false, preload: Bool = false) {
            self.maxAge = maxAge
            self.includeSubdomains = includeSubdomains
            self.preload = preload
        }

        var headerValue: String {
            var value = "max-age=\(maxAge.components.seconds)"
            if includeSubdomains { value += "; includeSubDomains" }
            if preload { value += "; preload" }
            return value
        }
    }

    /// `X-Content-Type-Options: nosniff` when true.
    public var contentTypeOptions: Bool
    public var frameOptions: FrameOptions?
    /// A `Referrer-Policy` token; checked against the specification's list.
    public var referrerPolicy: String?
    public var strictTransportSecurity: StrictTransportSecurity?
    /// Sent verbatim. Flight does not parse or validate CSP.
    public var contentSecurityPolicy: String?

    public init(
        contentTypeOptions: Bool = true,
        frameOptions: FrameOptions? = .deny,
        referrerPolicy: String? = "strict-origin-when-cross-origin",
        strictTransportSecurity: StrictTransportSecurity? = nil,
        contentSecurityPolicy: String? = nil
    ) throws {
        if let referrerPolicy, !Self.referrerPolicies.contains(referrerPolicy) {
            throw SecurityHeadersConfigurationError.unknownReferrerPolicy(referrerPolicy)
        }
        if let hsts = strictTransportSecurity {
            guard hsts.maxAge >= .zero else {
                throw SecurityHeadersConfigurationError.negativeHSTSMaxAge(hsts.maxAge)
            }
            // hstspreload.org's submission requirements. A preload directive
            // that the list would refuse is a promise nobody is keeping.
            if hsts.preload
                && (!hsts.includeSubdomains || hsts.maxAge < .seconds(31_536_000))
            {
                throw SecurityHeadersConfigurationError.preloadRequirementsNotMet
            }
        }
        if let csp = contentSecurityPolicy, csp.trimmingCharacters(in: .whitespaces).isEmpty {
            throw SecurityHeadersConfigurationError.emptyContentSecurityPolicy
        }
        self.contentTypeOptions = contentTypeOptions
        self.frameOptions = frameOptions
        self.referrerPolicy = referrerPolicy
        self.strictTransportSecurity = strictTransportSecurity
        self.contentSecurityPolicy = contentSecurityPolicy
    }

    /// The three default-on headers, nothing else.
    public static let `default` = try! SecurityHeaders()

    /// Nothing. What a hand-built `WebRuntime` uses, and what an application
    /// gets by switching every header off.
    public static let none = try! SecurityHeaders(
        contentTypeOptions: false, frameOptions: nil, referrerPolicy: nil)

    /// Reads `web.security-headers.*`. Absent keys take the defaults above;
    /// `off` switches a default-on header off. `false` means the same: YAML
    /// 1.1 reads an unquoted `off` as a boolean, and a provider that follows
    /// it hands the value over as `false`.
    public init(configuration: Configuration) throws {
        typealias Key = SecurityHeadersConfigKey
        func read(_ key: String) throws -> String? {
            try configuration.getIfPresent(key)
        }

        var contentTypeOptions = true
        if let raw = try read(Key.contentTypeOptions) {
            switch raw.lowercased() {
            case "nosniff": contentTypeOptions = true
            case "off", "false": contentTypeOptions = false
            default:
                throw SecurityHeadersConfigurationError.invalid(key: Key.contentTypeOptions, raw)
            }
        }

        var frameOptions: FrameOptions? = .deny
        if let raw = try read(Key.frameOptions) {
            switch raw.lowercased() {
            case "deny": frameOptions = .deny
            case "sameorigin": frameOptions = .sameOrigin
            case "off", "false": frameOptions = nil
            default: throw SecurityHeadersConfigurationError.invalid(key: Key.frameOptions, raw)
            }
        }

        var referrerPolicy: String? = "strict-origin-when-cross-origin"
        if let raw = try read(Key.referrerPolicy) {
            referrerPolicy = ["off", "false"].contains(raw.lowercased()) ? nil : raw
        }

        var hsts: StrictTransportSecurity?
        let includeSubdomains: Bool? = try configuration.getIfPresent(Key.hstsIncludeSubdomains)
        let preload: Bool? = try configuration.getIfPresent(Key.hstsPreload)
        if let maxAge: Duration = try configuration.getIfPresent(Key.hstsMaxAge) {
            hsts = StrictTransportSecurity(
                maxAge: maxAge, includeSubdomains: includeSubdomains ?? false,
                preload: preload ?? false)
        } else if includeSubdomains != nil || preload != nil {
            // Modifiers with no max-age would otherwise be silently ignored,
            // leaving an operator believing HSTS is on.
            throw SecurityHeadersConfigurationError.hstsModifierWithoutMaxAge
        }

        try self.init(
            contentTypeOptions: contentTypeOptions,
            frameOptions: frameOptions,
            referrerPolicy: referrerPolicy,
            strictTransportSecurity: hsts,
            contentSecurityPolicy: try read(Key.contentSecurityPolicy))
    }

    /// `response` with every configured header it does not already carry.
    func apply(to response: Response) -> Response {
        var result = response
        let existing = response.headers
        func fill(_ name: HTTPField.Name, _ value: String?) {
            guard let value, existing[name] == nil else { return }
            result = result.settingHeader(name, value)
        }
        fill(.xContentTypeOptions, contentTypeOptions ? "nosniff" : nil)
        fill(.xFrameOptions, frameOptions?.rawValue)
        fill(.referrerPolicy, referrerPolicy)
        fill(.strictTransportSecurity, strictTransportSecurity?.headerValue)
        fill(.contentSecurityPolicy, contentSecurityPolicy)
        return result
    }

    /// The W3C Referrer Policy tokens. A typo here would otherwise be sent,
    /// ignored by every browser, and leave the browser default in force.
    static let referrerPolicies: Set<String> = [
        "no-referrer", "no-referrer-when-downgrade", "origin", "origin-when-cross-origin",
        "same-origin", "strict-origin", "strict-origin-when-cross-origin", "unsafe-url",
    ]
}

public enum SecurityHeadersConfigKey {
    public static let root = "web.security-headers"
    /// `nosniff` (default) or `off`.
    public static let contentTypeOptions = "web.security-headers.content-type-options"
    /// `deny` (default), `sameorigin`, or `off`.
    public static let frameOptions = "web.security-headers.frame-options"
    /// A Referrer-Policy token, or `off`. Default `strict-origin-when-cross-origin`.
    public static let referrerPolicy = "web.security-headers.referrer-policy"
    /// A duration. Absent means no `Strict-Transport-Security` at all.
    public static let hstsMaxAge = "web.security-headers.hsts-max-age"
    public static let hstsIncludeSubdomains = "web.security-headers.hsts-include-subdomains"
    public static let hstsPreload = "web.security-headers.hsts-preload"
    /// Sent verbatim. Absent means none.
    public static let contentSecurityPolicy = "web.security-headers.content-security-policy"
}

/// A `web.security-headers.*` value that cannot mean what it says. Thrown at
/// composition, so a misconfigured header fails startup instead of silently
/// not being sent.
public enum SecurityHeadersConfigurationError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case invalid(key: String, String)
    case unknownReferrerPolicy(String)
    case negativeHSTSMaxAge(Duration)
    case preloadRequirementsNotMet
    case hstsModifierWithoutMaxAge
    case emptyContentSecurityPolicy

    public var description: String {
        switch self {
        case .invalid(let key, let value):
            return "\(key): '\(value)' is not a recognized value."
        case .unknownReferrerPolicy(let value):
            return
                "\(SecurityHeadersConfigKey.referrerPolicy): '\(value)' is not a Referrer-Policy token. "
                + "Use one of: \(SecurityHeaders.referrerPolicies.sorted().joined(separator: ", ")), or off."
        case .negativeHSTSMaxAge(let value):
            return "\(SecurityHeadersConfigKey.hstsMaxAge): \(value) is negative."
        case .preloadRequirementsNotMet:
            return
                "\(SecurityHeadersConfigKey.hstsPreload) requires hsts-include-subdomains: true and an "
                + "hsts-max-age of at least one year (31536000s); the preload list refuses anything less."
        case .hstsModifierWithoutMaxAge:
            return
                "hsts-include-subdomains or hsts-preload is set but \(SecurityHeadersConfigKey.hstsMaxAge) "
                + "is not, so no Strict-Transport-Security header would be sent. Set a max-age, or remove them."
        case .emptyContentSecurityPolicy:
            return "\(SecurityHeadersConfigKey.contentSecurityPolicy) is empty."
        }
    }
}

extension HTTPField.Name {
    // swift-http-types already names X-Content-Type-Options,
    // Strict-Transport-Security and Content-Security-Policy; these two it
    // does not. Force-unwrapped: literals, pinned valid by
    // `SecurityHeadersTests`.
    static let xFrameOptions = HTTPField.Name("x-frame-options")!
    static let referrerPolicy = HTTPField.Name("referrer-policy")!
}
