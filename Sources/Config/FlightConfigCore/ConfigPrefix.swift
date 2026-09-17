/// The one name every configuration spelling is derived from.
///
/// Flight's defaults are `flight.yaml`, `flight-{env}.yaml`, `FLIGHT_ENV` and
/// `FLIGHT_SERVER_PORT` — four spellings of the same word. This type holds
/// that word once and derives all four, so an application that needs a
/// different one changes it in a single place and cannot end up reading
/// `myapp.yaml` while looking for `FLIGHT_SERVER_PORT`.
///
/// Two reasons an application reaches for this:
///
/// - **Variable collisions.** `FLIGHT_` is a short prefix in a shared
///   environment. Two Flight services in one container, or a platform that
///   already injects `FLIGHT_*`, need their own namespace.
/// - **Naming.** A file called `flight.yaml` in someone else's repository
///   names the framework rather than the application.
///
/// ## The build-time check
///
/// `@ConfigValue` keys without a `default:` are verified against the base file
/// *at build time* by `flight-registration-gen`, which finds that file by its
/// default name. A build tool cannot see a value passed to
/// `Configuration.load` at runtime, and searching the package directory for
/// "some YAML file" would be discovery-by-presence — the pattern this
/// framework rejects everywhere else.
///
/// So a non-default prefix moves the base file out of the checker's reach and
/// the check is skipped. It is skipped *loudly*: the generator warns, naming
/// the keys it could not verify, rather than silently reporting success. Those
/// keys still fail at startup if they are genuinely missing — the guarantee
/// moves from compile time to boot time, it does not disappear.
public struct ConfigPrefix: Sendable, Equatable, Hashable {

    /// The lowercase word the spellings derive from, e.g. `flight`.
    public let rawValue: String

    /// Flight's default: `flight.yaml`, `FLIGHT_ENV`, `FLIGHT_*`.
    public static let `default` = ConfigPrefix("flight")

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

    /// The base layer's file name: `flight.yaml`.
    public var baseFileName: String { "\(rawValue).yaml" }

    /// The environment layer's file name, e.g. `flight-prod.yaml`.
    public func environmentFileName(for environment: FlightEnvironment) -> String {
        "\(rawValue)-\(environment.rawValue).yaml"
    }

    /// The variable naming the active environment: `FLIGHT_ENV`.
    public var environmentVariable: String { "\(rawValue.uppercased())_ENV" }

    /// The key → variable-name transform: uppercase, `.` → `_`, prefixed.
    /// `datasource.url` under the default prefix reads `FLIGHT_DATASOURCE_URL`.
    public func variableName(for key: String) -> String {
        "\(rawValue.uppercased())_" + key.uppercased().replacingOccurrences(of: ".", with: "_")
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
