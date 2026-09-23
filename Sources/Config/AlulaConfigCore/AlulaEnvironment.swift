import Foundation

/// The active deployment environment, resolved from `ALULA_ENV`.
///
/// `ALULA_ENV` is read once, at the start of bootstrap, and the result
/// selects which `alula-{env}.yaml` layers on top of the base file. Nothing
/// downstream re-reads it: code that needs to branch on environment reads a
/// configuration value instead.
///
/// ```swift
/// let environment = AlulaEnvironment.current()   // ALULA_ENV=staging → .staging
/// ```
///
/// ## Adding your own
///
/// This is a `RawRepresentable` struct rather than an enum, so deployments
/// with environments beyond the four built-in ones can add them without
/// waiting on this package:
///
/// ```swift
/// extension AlulaEnvironment {
///     static let qa = AlulaEnvironment("qa")           // loads alula-qa.yaml
///     static let preproduction = AlulaEnvironment("preproduction")
/// }
/// ```
///
/// A value that is not one of the built-ins is still a perfectly good
/// environment — `current(prefix:)` returns it as itself rather than silently
/// collapsing it to ``dev``.
public struct AlulaEnvironment: RawRepresentable, Sendable, Hashable, Codable {

    /// The environment name, as it appears in `ALULA_ENV` and in the
    /// `alula-{env}.yaml` filename.
    public let rawValue: String

    /// Creates an environment from its name.
    ///
    /// Never fails: any non-empty name is a valid environment, which is what
    /// makes the type extensible.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates an environment from its name.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Local development. The default when `ALULA_ENV` is unset.
    public static let dev = AlulaEnvironment("dev")

    /// Automated tests. A first-class environment so `alula-test.yaml` can
    /// sit alongside the others for integration-style tests that want real
    /// configuration loading rather than injected overrides.
    public static let test = AlulaEnvironment("test")

    /// Pre-production.
    public static let staging = AlulaEnvironment("staging")

    /// Production.
    public static let prod = AlulaEnvironment("prod")

    /// The four environments this package defines.
    ///
    /// Not every valid environment — the type is extensible, so an app may
    /// define more. Use it to enumerate the built-ins, not to validate input.
    public static let standard: [AlulaEnvironment] = [.dev, .test, .staging, .prod]

    /// Reads `ALULA_ENV` from the process environment.
    ///
    /// Defaults to ``dev`` when unset, since "no environment specified" is
    /// the normal local-development state.
    public static func current(prefix: ConfigPrefix = .default) -> AlulaEnvironment {
        current(from: ProcessInfo.processInfo.environment, prefix: prefix)
    }

    /// Resolves `ALULA_ENV` from an explicit dictionary.
    ///
    /// The seam tests use instead of mutating the real process environment.
    /// `Configuration.load` routes through this, so the whole load path is
    /// reproducible from a plain dictionary.
    ///
    /// An unset or empty value resolves to ``dev``. Any other value resolves
    /// to itself — `ALULA_ENV=qa` gives you `qa`, and therefore
    /// `alula-qa.yaml`, rather than quietly loading development
    /// configuration under a production-shaped name.
    public static func current(
        from environment: [String: String],
        prefix: ConfigPrefix = .default
    ) -> AlulaEnvironment {
        guard let raw = environment[prefix.environmentVariable], !raw.isEmpty else {
            return .dev
        }
        return AlulaEnvironment(raw)
    }
}

extension AlulaEnvironment: CustomStringConvertible {
    public var description: String { rawValue }
}

extension AlulaEnvironment: ExpressibleByStringLiteral {
    /// Lets an environment be written as a plain string literal where the
    /// type is already known.
    ///
    /// ```swift
    /// let environment: AlulaEnvironment = "staging"
    /// ```
    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}
