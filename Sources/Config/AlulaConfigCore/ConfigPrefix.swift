/// The one name every configuration spelling is derived from.
///
/// Alula's defaults are `alula.yaml`, `alula-{env}.yaml`, `ALULA_ENV` and
/// `ALULA_SERVER_PORT` — four spellings of the same word. This type holds
/// that word once and derives all four, so an application that needs a
/// different one changes it in a single place and cannot end up reading
/// `myapp.yaml` while looking for `ALULA_SERVER_PORT`.
///
/// Two reasons an application reaches for this:
///
/// - **Variable collisions.** `ALULA_` is a short prefix in a shared
///   environment. Two Alula services in one container, or a platform that
///   already injects `ALULA_*`, need their own namespace.
/// - **Naming.** A file called `alula.yaml` in someone else's repository
///   names the framework rather than the application.
///
/// ## The build-time check still applies
///
/// `@ConfigValue` keys without a `default:` are verified against the base file
/// *at build time*, and a custom prefix does not give that up. The prefix
/// looks like a runtime value because `load` takes it at runtime, but an
/// application writes it as a literal in its own source — and that source is
/// already scanned. `alula-registration-gen` reads the `prefix:` argument and
/// checks against `<prefix>.yaml`, exactly as it does for `alula.yaml`.
///
/// Nothing is discovered from the filesystem. An unscanned prefix means the
/// default name, never "whatever YAML is lying around" — file presence decides
/// nothing here.
///
/// Two cases are not statically knowable, and both say so rather than passing
/// quietly. An interpolated or computed prefix, and two literals that
/// disagree, leave the base file unidentifiable: the build warns and those keys
/// are verified at startup instead. A literal that is not a *legal* prefix is a
/// build error — `Configuration.load` would trap on it at startup, and the name
/// is knowable here.
public struct ConfigPrefix: Sendable, Equatable, Hashable {

    /// The lowercase word the spellings derive from, e.g. `alula`.
    public let rawValue: String

    /// Alula's default: `alula.yaml`, `ALULA_ENV`, `ALULA_*`.
    public static let `default` = ConfigPrefix("alula")

    /// - Parameter rawValue: A non-empty word of lowercase ASCII letters,
    ///   digits and underscores, starting with a letter.
    ///
    ///   The constraint is not fussiness: the uppercase form becomes an
    ///   environment-variable prefix, and a dash or a leading digit produces a
    ///   name most shells cannot set — a configuration that looks fine and
    ///   silently cannot be overridden at deploy time. Invalid input traps
    ///   here, at the one call site in an application's lifetime, rather than
    ///   yielding unusable variable names much later.
    public init(_ rawValue: String) {
        precondition(!rawValue.isEmpty, "A config prefix cannot be empty.")
        precondition(
            rawValue.first!.isASCII && rawValue.first!.isLetter && rawValue.first!.isLowercase,
            """
            Config prefix '\(rawValue)' must start with a lowercase ASCII letter — \
            its uppercased form is an environment-variable prefix, and \
            '\(rawValue.uppercased())_SERVER_PORT' would not be a name most shells can set.
            """
        )
        precondition(
            rawValue.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") },
            """
            Config prefix '\(rawValue)' may contain only lowercase ASCII letters, digits \
            and underscores. A dash or a dot would produce the variable name \
            '\(rawValue.uppercased())_SERVER_PORT' with a character shells cannot set.
            """
        )
        self.rawValue = rawValue
    }

    /// The same validation as ``init(_:)``, reporting failure instead of
    /// trapping.
    ///
    /// For callers that did not write the string themselves. The build tool
    /// reads the prefix out of an application's own source, where a bad value
    /// is the author's typo rather than a programmer error in the caller —
    /// trapping there would crash codegen instead of pointing at the line.
    /// It turns an invalid prefix into a build error rather than a startup
    /// trap, which is where the rest of `@ConfigValue` checking already lives.
    public init?(validating rawValue: String) {
        guard let first = rawValue.first,
            first.isASCII, first.isLetter, first.isLowercase,
            rawValue.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") })
        else { return nil }
        self.rawValue = rawValue
    }

    /// The base layer's file name: `alula.yaml`.
    public var baseFileName: String { "\(rawValue).yaml" }

    /// The environment layer's file name, e.g. `alula-prod.yaml`.
    public func environmentFileName(for environment: AlulaEnvironment) -> String {
        "\(rawValue)-\(environment.rawValue).yaml"
    }

    /// The variable naming the active environment: `ALULA_ENV`.
    public var environmentVariable: String { "\(rawValue.uppercased())_ENV" }

    /// The key → variable-name transform: uppercase, every character that is
    /// not a letter or digit → `_`, prefixed. `datasource.url` reads
    /// `ALULA_DATASOURCE_URL`, and `pubsub.node-id` reads
    /// `ALULA_PUBSUB_NODE_ID`.
    ///
    /// It has to agree with how the runtime reads the environment —
    /// swift-configuration's key encoder, which maps a dash to `_` as it
    /// does a dot. Mapping only the dot named `ALULA_PUBSUB_NODE-ID` in a
    /// missing-key error: a variable most shells cannot set, and one nothing
    /// reads.
    public func variableName(for key: String) -> String {
        "\(rawValue.uppercased())_"
            + key.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
    }
}

extension ConfigPrefix: CustomStringConvertible {
    public var description: String { rawValue }
}

extension ConfigPrefix: ExpressibleByStringLiteral {
    /// Lets a prefix be written as a plain literal: `prefix: "myapp"`.
    public init(stringLiteral value: String) {
        self.init(value)
    }
}
