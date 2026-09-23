import FlightTelemetry

/// What sign-in reports, as telemetry events — Flight's own providers, and
/// any provider of yours that emits them too, which is what puts a custom
/// sign-in on the same dashboards as the built-in ones.
///
/// ``FlightSecurityModule`` contributes ``SignInMetrics/definitions``, so an
/// application with `FlightTelemetryModule` reports these as the counters
/// 0.33 did, under the same names.
public enum SignInEvents {
    /// A sign-in sent to an external provider.
    @TelemetryEvent("flight.sign_in.started")
    public enum Started {
        public struct Metadata {
            /// `oidc`, or your provider's name.
            public var provider: String
        }
    }

    /// A sign-in finished, either way.
    @TelemetryEvent("flight.sign_in.attempt")
    public enum Attempt {
        public struct Measurements {
            /// From the attempt's start — for a password, mostly hashing.
            public var duration: Duration
        }
        public struct Metadata {
            /// `password`, `oidc`, or your provider's name.
            public var provider: String
            /// `success`, or why not — `invalid_credentials`,
            /// `account_disabled`, `throttled`, `unavailable` for passwords;
            /// `provider_refused`, `invalid_callback`, `token_exchange`,
            /// `invalid_id_token`, `userinfo`, `userinfo_subject_mismatch`,
            /// `discovery`, `configuration` for OIDC.
            public var outcome: String
        }
    }

    /// A stored password hash upgraded at sign-in — stronger parameters, or
    /// the pre-0.33 normalization.
    @TelemetryEvent("flight.sign_in.password_rehashed")
    public enum PasswordRehashed {}

    /// A session sign-in that reached `sessions.authenticated-lifetime` and
    /// was signed out.
    @TelemetryEvent("flight.sign_in.expired")
    public enum Expired {}

    /// A one-time token issued.
    @TelemetryEvent("flight.one_time_tokens.issued")
    public enum TokenIssued {
        public struct Metadata {
            public var purpose: String
        }
    }

    /// A one-time token redemption, either way. The caller is told only
    /// "invalid or expired"; this is where the difference is kept.
    @TelemetryEvent("flight.one_time_tokens.redemption")
    public enum TokenRedemption {
        public struct Metadata {
            public var purpose: String
            /// `redeemed`, `unknown_or_used`, `expired`, `wrong_purpose`,
            /// `binding_mismatch`.
            public var outcome: String
        }
    }

    /// Reads the clock for an attempt's duration only if an ``Attempt``
    /// will be seen.
    static func attemptStarted() -> ContinuousClock.Instant? {
        Telemetry.isEnabled(Attempt.self) ? .now : nil
    }

    static func attempt(_ provider: String, _ outcome: String, since start: ContinuousClock.Instant?) {
        Telemetry.emit(Attempt.self) {
            (
                .init(duration: start.map { .now - $0 } ?? .zero),
                .init(provider: provider, outcome: outcome)
            )
        }
    }
}

/// The sign-in and one-time-token counters: their names, and their
/// definitions over ``SignInEvents``.
///
/// Every dimension is a closed set — a provider name, an outcome, a token
/// purpose the application declared — never an identifier, a subject or an
/// address, so a metrics backend's series count stays fixed however many
/// people sign in.
public enum SignInMetrics {
    /// ``SignInEvents/Started``, counted by `provider`.
    public static let started = "flight_sign_in_started"
    /// ``SignInEvents/Attempt``, counted by `provider` and `outcome`.
    public static let attempts = "flight_sign_in_attempts"
    /// ``SignInEvents/Attempt``'s duration, by `provider`.
    public static let duration = "flight_sign_in_duration"
    /// ``SignInEvents/PasswordRehashed``, counted.
    public static let passwordRehashes = "flight_sign_in_password_rehashes"
    /// ``SignInEvents/Expired``, counted.
    public static let expired = "flight_sign_in_expired"
    /// ``SignInEvents/TokenIssued``, counted by `purpose`.
    public static let tokensIssued = "flight_one_time_tokens_issued"
    /// ``SignInEvents/TokenRedemption``, counted by `purpose` and `outcome`.
    public static let tokensRedeemed = "flight_one_time_tokens_redeemed"

    /// What ``FlightSecurityModule`` contributes to the reported metrics.
    public static let definitions: [TelemetryMetric] = [
        .counter(SignInEvents.Started.self, tags: \.provider),
        .counter(SignInEvents.Attempt.self, name: "flight.sign_in.attempts", tags: \.provider, \.outcome),
        .distribution(
            SignInEvents.Attempt.self, \.duration, name: "flight.sign_in.duration", unit: .milliseconds,
            tags: \.provider),
        .counter(SignInEvents.PasswordRehashed.self, name: "flight.sign_in.password_rehashes"),
        .counter(SignInEvents.Expired.self),
        .counter(SignInEvents.TokenIssued.self, tags: \.purpose),
        .counter(
            SignInEvents.TokenRedemption.self, name: "flight.one_time_tokens.redeemed",
            tags: \.purpose, \.outcome),
    ]
}

extension PasswordAuthenticationError {
    var metricOutcome: String {
        switch self {
        case .invalidCredentials: "invalid_credentials"
        case .accountDisabled: "account_disabled"
        case .throttled: "throttled"
        case .unavailable: "unavailable"
        }
    }
}

extension OIDCSignInError {
    var metricOutcome: String {
        switch self {
        case .configuration: "configuration"
        case .discovery: "discovery"
        case .providerRefused: "provider_refused"
        case .invalidCallback: "invalid_callback"
        case .tokenExchange: "token_exchange"
        case .invalidIDToken: "invalid_id_token"
        case .userInfo: "userinfo"
        case .userInfoSubjectMismatch: "userinfo_subject_mismatch"
        }
    }
}
