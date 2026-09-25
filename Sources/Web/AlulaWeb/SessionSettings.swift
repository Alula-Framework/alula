import AlulaCore
import Foundation

/// The `sessions.*` configuration vocabulary (env-var form `ALULA_SESSIONS_*`).
///
/// Kebab-case from the start. `security.oidc.*` shipped snake_case and had
/// to grow a second spelling of every key in 0.22.1; there is no reason to
/// repeat that.
public enum SessionConfigKey {
    public static let root = "sessions"
    /// `sessions.cookie-name` — the cookie the id travels in.
    public static let cookieName = "sessions.cookie-name"
    /// `sessions.ttl` — idle timeout, sliding: renewed on writes, and on
    /// reads once less than half of it is left.
    public static let ttl = "sessions.ttl"
    /// `sessions.cookie-secure` — the `Secure` attribute. On by default.
    public static let cookieSecure = "sessions.cookie-secure"
    /// `sessions.cookie-same-site` — `strict`, `lax` or `none`.
    public static let cookieSameSite = "sessions.cookie-same-site"
    /// `sessions.cookie-path`
    public static let cookiePath = "sessions.cookie-path"
    /// `sessions.cookie-domain` — unset means the request's host only.
    public static let cookieDomain = "sessions.cookie-domain"
    /// `sessions.memory.max-entries` — the in-memory store's bound.
    public static let memoryMaxEntries = "sessions.memory.max-entries"
    /// `sessions.authenticated-lifetime` — how long a sign-in lasts however
    /// active the session is. Absolute, not sliding.
    public static let authenticatedLifetime = "sessions.authenticated-lifetime"
    /// `sessions.cookie-host-prefix` — name the cookie `__Host-<name>`.
    public static let cookieHostPrefix = "sessions.cookie-host-prefix"
}

/// Loaded, validated settings — read once at composition, so a bad value
/// fails startup rather than the first request that sets a cookie.
public struct SessionSettings: Sendable, Equatable {
    public var cookieName: String
    public var ttl: Duration
    public var cookieSecure: Bool
    public var cookieSameSite: Cookie.SameSite
    public var cookiePath: String
    public var cookieDomain: String?
    public var memoryMaxEntries: Int
    /// How long a signed-in principal lasts in a session, counted from the
    /// sign-in, however active the session stays. `ttl` is sliding — an
    /// active session never idles out — which is right for a cart and wrong
    /// for authority: a stolen signed-in cookie used continuously would
    /// otherwise last forever. Past this, `Authentication` signs the session
    /// out and the browser signs in again; the rest of the session survives.
    public var authenticatedLifetime: Duration
    /// Names the cookie `__Host-<cookieName>`, which browsers accept only
    /// when it is `Secure`, has `Path=/` and no `Domain` — so no subdomain
    /// can set or overwrite it. Off by default because renaming the cookie
    /// signs everyone out once, and because a deployment that shares the
    /// cookie across subdomains cannot use it.
    public var cookieHostPrefix: Bool

    /// The name the cookie is actually set and read under.
    public var effectiveCookieName: String {
        cookieHostPrefix ? "__Host-" + cookieName : cookieName
    }

    /// The defaults, written once, for the memberwise initializer and the
    /// configuration reader alike.
    public enum Defaults {
        public static let cookieName = "session"
        /// Two weeks idle. Long enough that a weekly visitor stays signed
        /// in; short enough that a session on a shared machine does not
        /// outlive the memory of having used it.
        public static let ttl: Duration = .seconds(14 * 24 * 60 * 60)
        /// On. `Cookie` itself defaults `isSecure` to false because a bare
        /// cookie API cannot know its deployment; a session cookie is a
        /// bearer credential and the framework does know what it is.
        /// Development on plain HTTP sets it false in the dev overlay —
        /// Chrome and Firefox accept `Secure` cookies from `localhost`,
        /// Safari does not.
        public static let cookieSecure = true
        public static let cookieSameSite = Cookie.SameSite.lax
        public static let cookiePath = "/"
        public static let memoryMaxEntries = 100_000
        /// A week. Long enough that signing in is not a daily chore, short
        /// enough that a stolen cookie stops working on its own. A
        /// high-value application sets this in hours.
        public static let authenticatedLifetime: Duration = .seconds(7 * 24 * 60 * 60)
        public static let cookieHostPrefix = false
    }

    public init(
        cookieName: String = Defaults.cookieName,
        ttl: Duration = Defaults.ttl,
        cookieSecure: Bool = Defaults.cookieSecure,
        cookieSameSite: Cookie.SameSite = Defaults.cookieSameSite,
        cookiePath: String = Defaults.cookiePath,
        cookieDomain: String? = nil,
        memoryMaxEntries: Int = Defaults.memoryMaxEntries,
        authenticatedLifetime: Duration = Defaults.authenticatedLifetime,
        cookieHostPrefix: Bool = Defaults.cookieHostPrefix
    ) throws {
        self.cookieName = cookieName
        self.ttl = ttl
        self.cookieSecure = cookieSecure
        self.cookieSameSite = cookieSameSite
        self.cookiePath = cookiePath
        self.cookieDomain = cookieDomain
        self.memoryMaxEntries = memoryMaxEntries
        self.authenticatedLifetime = authenticatedLifetime
        self.cookieHostPrefix = cookieHostPrefix
        try validate()
    }

    /// Reads `sessions.*`. Absent keys take the defaults; a present key that
    /// does not decode throws, naming it.
    public init(configuration: Configuration) throws {
        try self.init(
            cookieName: try configuration.getIfPresent(SessionConfigKey.cookieName)
                ?? Defaults.cookieName,
            ttl: try configuration.getIfPresent(SessionConfigKey.ttl) ?? Defaults.ttl,
            cookieSecure: try configuration.getIfPresent(SessionConfigKey.cookieSecure)
                ?? Defaults.cookieSecure,
            cookieSameSite: try configuration.getIfPresent(SessionConfigKey.cookieSameSite)
                ?? Defaults.cookieSameSite,
            cookiePath: try configuration.getIfPresent(SessionConfigKey.cookiePath)
                ?? Defaults.cookiePath,
            cookieDomain: try configuration.getIfPresent(SessionConfigKey.cookieDomain),
            memoryMaxEntries: try configuration.getIfPresent(SessionConfigKey.memoryMaxEntries)
                ?? Defaults.memoryMaxEntries,
            authenticatedLifetime: try configuration.getIfPresent(
                SessionConfigKey.authenticatedLifetime) ?? Defaults.authenticatedLifetime,
            cookieHostPrefix: try configuration.getIfPresent(SessionConfigKey.cookieHostPrefix)
                ?? Defaults.cookieHostPrefix)
    }

    private func validate() throws {
        // `Cookie.init` traps on a bad name, which is right for a literal at a
        // call site and wrong for a value an operator typed into YAML.
        guard !cookieName.isEmpty, !cookieName.contains(where: Self.isForbiddenInCookieName) else {
            throw SessionConfigurationError.invalidCookieName(cookieName)
        }
        guard ttl > .zero else {
            throw SessionConfigurationError.nonPositiveTTL(ttl)
        }
        // Browsers reject `SameSite=None` without `Secure` outright, so the
        // combination cannot produce a cookie that is ever sent back.
        if cookieSameSite == .none, !cookieSecure {
            throw SessionConfigurationError.sameSiteNoneRequiresSecure
        }
        guard memoryMaxEntries > 0 else {
            throw SessionConfigurationError.invalidMaxEntries(memoryMaxEntries)
        }
        guard authenticatedLifetime > .zero else {
            throw SessionConfigurationError.nonPositiveAuthenticatedLifetime(authenticatedLifetime)
        }
        // The browser's own rules for the prefix (RFC 6265bis §4.1.3.2). A
        // cookie that breaks them is silently dropped, which would read as
        // "nobody can stay signed in".
        if cookieHostPrefix, !cookieSecure || cookiePath != "/" || cookieDomain != nil {
            throw SessionConfigurationError.hostPrefixRequirementsNotMet
        }
    }

    private static func isForbiddenInCookieName(_ character: Character) -> Bool {
        character == "=" || character == ";" || character == ","
            || character.isWhitespace || character.unicodeScalars.contains { $0.value < 0x21 }
    }
}

/// A `sessions.*` value that cannot be used. Thrown at composition.
public enum SessionConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidCookieName(String)
    case nonPositiveTTL(Duration)
    case sameSiteNoneRequiresSecure
    case invalidMaxEntries(Int)
    case nonPositiveAuthenticatedLifetime(Duration)
    case hostPrefixRequirementsNotMet

    public var description: String {
        switch self {
        case .invalidCookieName(let name):
            return """
                \(SessionConfigKey.cookieName) is "\(name)", which cannot be a Set-Cookie name \
                (empty, or containing =, ;, comma, whitespace, or a control character).
                """
        case .nonPositiveTTL(let ttl):
            return "\(SessionConfigKey.ttl) must be positive; it is \(ttl)."
        case .sameSiteNoneRequiresSecure:
            return """
                \(SessionConfigKey.cookieSameSite) is "none" but \(SessionConfigKey.cookieSecure) \
                is false. Browsers reject SameSite=None without Secure, so that cookie would never \
                be sent back. Set \(SessionConfigKey.cookieSecure) to true, or use "lax".
                """
        case .invalidMaxEntries(let value):
            return """
                \(SessionConfigKey.memoryMaxEntries) must be positive; it is \(value). The in-memory \
                store is bounded by design.
                """
        case .nonPositiveAuthenticatedLifetime(let value):
            return "\(SessionConfigKey.authenticatedLifetime) must be positive; it is \(value)."
        case .hostPrefixRequirementsNotMet:
            return """
                \(SessionConfigKey.cookieHostPrefix) is on, which browsers accept only for a cookie \
                that is Secure, has Path=/ and no Domain. Set \(SessionConfigKey.cookieSecure): true, \
                \(SessionConfigKey.cookiePath): /, and no \(SessionConfigKey.cookieDomain) — or turn \
                the prefix off.
                """
        }
    }
}

extension Cookie.SameSite: ConfigDecodable {
    /// `strict`, `lax` or `none`, case-insensitively.
    public init?(configValue: String) {
        switch configValue.trimmingCharacters(in: .whitespaces).lowercased() {
        case "strict": self = .strict
        case "lax": self = .lax
        case "none": self = .none
        default: return nil
        }
    }
}

extension SessionConfigurationError: ModuleConfigurationError {}
