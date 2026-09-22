import FlightCore
import FlightRateLimit
import FlightWeb

/// Password sign-in against the application's own accounts.
///
/// ```swift
/// modules: [
///     FlightWebModule<FlightTransport>.self,
///     FlightPasswordSignInModule.self,   // ← or FlightOIDCSignInModule.self
///     AppModule.self,                    // provides `credentialStore: any CredentialStore`
/// ]
/// ```
///
/// Provides `signInProvider: any SignInProvider` — the same type
/// ``FlightOIDCSignInModule`` provides, so a controller written against it
/// runs unchanged when the application moves to an external provider. The
/// two cannot both be listed: two providers of one type is refused at build
/// time, which is the right answer to "which one signs people in?".
///
/// Takes the application's `any CredentialStore` and `FlightRateLimitModule`'s
/// `RateLimiter`, matched by type. Reads `security.password.issuer` for the
/// principals it produces; `local` when unset.
public final class FlightPasswordSignInModule: FlightModule {
    public static var dependencies: [any FlightModule.Type] {
        [FlightSecurityModule.self, FlightSessionsModule.self, FlightRateLimitModule.self]
    }

    /// The authenticator, for registration and password-change flows that
    /// need ``PasswordAuthenticator/hashNewPassword(_:)``.
    public let passwordAuthenticator: PasswordAuthenticator

    /// The provider, as the seam type controllers inject.
    public let signInProvider: any SignInProvider

    public init(configuration: Configuration, store: any CredentialStore, limiter: RateLimiter)
        throws
    {
        let issuer: String = try configuration.getIfPresent("security.password.issuer") ?? "local"
        let authenticator = PasswordAuthenticator(store: store, issuer: issuer, limiter: limiter)
        self.passwordAuthenticator = authenticator
        self.signInProvider = PasswordSignIn(authenticator: authenticator)
    }

    public init() {
        preconditionFailure(
            "FlightPasswordSignInModule takes a credential store and a rate limiter in "
                + "init(configuration:store:limiter:). Provide `any CredentialStore` from one of "
                + "your modules, list FlightRateLimitModule, and compose with flightComposeModules."
        )
    }
}

/// Sign-in through an external OpenID Connect provider — Keycloak, Auth0,
/// Okta, Entra, Descope — configured from `security.oidc.*` (see
/// ``OIDCSignInConfiguration``).
///
/// Provides the same `signInProvider: any SignInProvider` as
/// ``FlightPasswordSignInModule``. It does not also validate bearer tokens:
/// list ``FlightOIDCModule`` beside it for an API that accepts them, and the
/// two share one `security.oidc` block.
public final class FlightOIDCSignInModule: FlightModule {
    public static var dependencies: [any FlightModule.Type] {
        [FlightSecurityModule.self, FlightSessionsModule.self]
    }

    public let settings: OIDCSignInConfiguration
    public let signInProvider: any SignInProvider

    public init(configuration: Configuration) throws {
        let settings = try OIDCSignInConfiguration(configuration: configuration)
        self.settings = settings
        self.signInProvider = OIDCSignIn(configuration: settings)
    }

    public init() {
        preconditionFailure(
            "FlightOIDCSignInModule takes its configuration in init(configuration:). Compose with "
                + "flightComposeModules.")
    }
}
