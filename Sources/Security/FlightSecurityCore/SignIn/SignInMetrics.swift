import CoreMetrics

/// The sign-in and one-time-token counters, by label.
///
/// Every dimension is a closed set — a provider name, an outcome, a token
/// purpose the application declared — never an identifier, a subject or an
/// address, so a metrics backend's series count stays fixed however many
/// people sign in. Nothing here picks a backend: the application bootstraps
/// `MetricsSystem`, and every emitting type also takes a factory, which is
/// how tests assert on counts.
public enum SignInMetrics {
    /// A sign-in sent to an external provider. `provider`: `oidc`.
    public static let started = "flight_sign_in_started"
    /// A sign-in finished, either way. `provider`: `password` or `oidc`;
    /// `outcome`: `success`, or why not — `invalid_credentials`,
    /// `account_disabled`, `throttled`, `unavailable` for passwords;
    /// `provider_refused`, `invalid_callback`, `token_exchange`,
    /// `invalid_id_token`, `userinfo`, `userinfo_subject_mismatch`,
    /// `discovery`, `configuration` for OIDC.
    public static let attempts = "flight_sign_in_attempts"
    /// A stored password hash upgraded at sign-in — stronger parameters, or
    /// the pre-0.33 normalization.
    public static let passwordRehashes = "flight_sign_in_password_rehashes"
    /// A session sign-in that reached `sessions.authenticated-lifetime` and
    /// was signed out.
    public static let expired = "flight_sign_in_expired"
    /// A one-time token issued. `purpose`.
    public static let tokensIssued = "flight_one_time_tokens_issued"
    /// A one-time token redemption. `purpose`, and `outcome`: `redeemed`,
    /// `unknown_or_used`, `expired`, `wrong_purpose`, `binding_mismatch`.
    /// The caller is told only "invalid or expired"; this is where the
    /// difference is kept.
    public static let tokensRedeemed = "flight_one_time_tokens_redeemed"

    static func attempt(_ provider: String, _ outcome: String, _ factory: any MetricsFactory) {
        Counter(
            label: attempts, dimensions: [("provider", provider), ("outcome", outcome)],
            factory: factory
        ).increment()
    }
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
