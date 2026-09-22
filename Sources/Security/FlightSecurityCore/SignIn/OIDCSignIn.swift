import Crypto
import FlightCore
import FlightWeb
import Foundation

/// What ``OIDCSignIn`` needs: who the provider is, who this application is
/// to it, and where the browser comes back.
///
/// ```yaml
/// security:
///   oidc:
///     issuer: "https://keycloak.example.com/realms/main"
///     client-id: "my-app"
///     client-secret: "…"                     # omit for a public client
///     redirect-uri: "https://app.example.com/auth/callback"
///     post-logout-redirect-uri: "https://app.example.com/"
///     sign-in-scopes: "openid profile email"  # the default
/// ```
///
/// `issuer`, the transport policy and the roles claims are the same keys the
/// token validator reads, so one `security.oidc` block configures both.
public struct OIDCSignInConfiguration: Sendable {
    public var issuer: String
    public var clientID: String
    /// Nil for a public client, which proves itself with PKCE alone. A
    /// confidential client sends this too, as HTTP Basic.
    public var clientSecret: String?
    /// Must match a redirect URI registered with the provider, exactly.
    public var redirectURI: URL
    public var postLogoutRedirectURI: URL?
    public var scopes: [String]
    /// How the ID token is checked: issuer, audience (this client), keys,
    /// clock skew, roles claims. Derived from the fields above unless given.
    public var validation: OIDCSecurityConfiguration
    /// How long a started sign-in may take before its state expires.
    public var pendingLifetime: Duration

    public static let defaultScopes = ["openid", "profile", "email"]

    public init(
        issuer: String,
        clientID: String,
        clientSecret: String? = nil,
        redirectURI: URL,
        postLogoutRedirectURI: URL? = nil,
        scopes: [String] = OIDCSignInConfiguration.defaultScopes,
        transport: JWKSTransportPolicy = .httpsOnly,
        rolesClaims: [String] = OIDCSecurityConfiguration.Defaults.rolesClaims,
        pendingLifetime: Duration = .seconds(600)
    ) throws {
        guard scopes.contains("openid") else {
            // Without it there is no ID token, and no one to sign in.
            throw OIDCSignInError.configuration("sign-in-scopes must include openid")
        }
        self.issuer = issuer
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.postLogoutRedirectURI = postLogoutRedirectURI
        self.scopes = scopes
        self.pendingLifetime = pendingLifetime
        // The ID token's audience is this client — not the API audience a
        // bearer token carries, which is why validation is its own copy.
        self.validation = try OIDCSecurityConfiguration(
            issuer: issuer, audience: clientID, jwksTransport: transport, rolesClaims: rolesClaims)
    }

    /// Reads `security.oidc.*`. `issuer`, `client-id` and `redirect-uri` are
    /// required; a missing one fails composition.
    public init(configuration: Configuration) throws {
        typealias S = OIDCSecurityConfiguration
        func string(_ name: String) throws -> String? {
            try S.setting(configuration, name, as: String.self)
        }
        guard let clientID = try string("client-id") else {
            throw OIDCSignInError.configuration("security.oidc.client-id is required")
        }
        guard let rawRedirect = try string("redirect-uri"), let redirect = URL(string: rawRedirect),
            redirect.scheme != nil
        else {
            throw OIDCSignInError.configuration(
                "security.oidc.redirect-uri is required and must be an absolute URL")
        }
        let postLogout = try string("post-logout-redirect-uri").flatMap(URL.init(string:))
        let scopes =
            try string("sign-in-scopes").map {
                $0.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
            } ?? Self.defaultScopes
        let rolesClaims =
            try string("roles-claim").map {
                $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } ?? OIDCSecurityConfiguration.Defaults.rolesClaims
        try self.init(
            issuer: configuration.get("security.oidc.issuer", as: String.self),
            clientID: clientID,
            clientSecret: try string("client-secret"),
            redirectURI: redirect,
            postLogoutRedirectURI: postLogout,
            scopes: scopes,
            transport: try S.transportPolicy(string("jwks-transport")),
            rolesClaims: rolesClaims)
    }
}

/// Sign-in through any OpenID Connect provider — Keycloak, Auth0, Okta,
/// Entra, Descope — by the authorization-code flow with PKCE (RFC 7636),
/// which OAuth 2.1 makes the only flow for a browser.
///
/// ``beginSignIn(_:returnTo:)`` sends the browser to the provider with a
/// fresh `state`, `nonce` and PKCE challenge, keeping the three in the
/// session. The provider sends it back to `redirect-uri`, where
/// ``completeSignIn(_:)`` matches `state`, exchanges the code — proving it
/// is the client that started, with the PKCE verifier — and validates the
/// ID token exactly as a bearer token is validated, plus its `nonce`. The
/// principal that comes out carries the provider's standard claims under
/// the same names ``PasswordSignIn`` uses.
///
/// No tokens are kept. The ID token is used once, to establish who signed
/// in, and the session holds the principal, as it does for every other
/// sign-in. An application that also needs to call APIs as the user wants
/// the access token, and that is a different feature.
public final class OIDCSignIn: SignInProvider {
    private let configuration: OIDCSignInConfiguration
    private let metadata: OIDCMetadataSource
    private let poster: any HTTPFormPosting
    private let validator: OIDCTokenValidator
    private let now: @Sendable () -> Date

    public convenience init(configuration: OIDCSignInConfiguration) {
        let policy = configuration.validation.jwksTransport
        self.init(
            configuration: configuration,
            http: AsyncHTTPGetter(timeout: .seconds(10), policy: policy),
            poster: AsyncHTTPFormPoster(timeout: .seconds(10), policy: policy),
            jwksSource: nil)
    }

    init(
        configuration: OIDCSignInConfiguration,
        http: any HTTPGetting,
        poster: any HTTPFormPosting,
        jwksSource: (any JWKSSource)?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        let policy = configuration.validation.jwksTransport
        self.metadata = OIDCMetadataSource(issuer: configuration.issuer, http: http, policy: policy)
        self.poster = poster
        self.validator = OIDCTokenValidator(
            configuration: configuration.validation,
            jwksSource: jwksSource
                ?? HTTPJWKSSource(
                    issuer: configuration.issuer, jwksURL: configuration.validation.jwksURL,
                    transportPolicy: policy),
            now: now)
        self.now = now
    }

    // MARK: Begin

    public func beginSignIn(_ context: RequestContext, returnTo: String?) async throws -> SignInStep
    {
        let metadata = try await metadata.metadata()
        let pending = PendingSignIn(
            state: Self.randomToken(), nonce: Self.randomToken(), verifier: Self.randomToken(),
            returnTo: SignInReturnPath.validated(returnTo), startedAt: now())
        try PendingSignIn.store(
            pending, in: context.requireSession(), now: now(),
            lifetime: configuration.pendingLifetime)

        var components = URLComponents(
            url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: pending.state),
            URLQueryItem(name: "nonce", value: pending.nonce),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: pending.verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        components?.percentEncodedQuery = items.map {
            "\(FormEncoding.encode($0.name))=\(FormEncoding.encode($0.value ?? ""))"
        }.joined(separator: "&")
        guard let url = components?.url else {
            throw OIDCSignInError.discovery("authorization endpoint is not a usable URL")
        }
        return .redirect(url)
    }

    // MARK: Complete

    public func completeSignIn(_ context: RequestContext) async throws -> SignInResult {
        let request = context.request
        if let error = request.queryParam("error") {
            // The user declined, or the provider refused. Not a fault here.
            throw OIDCSignInError.providerRefused(error)
        }
        guard let code = request.queryParam("code"), let state = request.queryParam("state") else {
            throw OIDCSignInError.invalidCallback("missing code or state")
        }
        let session = try context.requireSession()
        // Single use: taken out whether or not what follows succeeds, so a
        // replayed callback finds nothing.
        guard
            let pending = try PendingSignIn.take(
                state: state, from: session, now: now(), lifetime: configuration.pendingLifetime)
        else {
            throw OIDCSignInError.invalidCallback("unknown or expired state")
        }

        let metadata = try await metadata.metadata()
        var fields = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", configuration.redirectURI.absoluteString),
            ("code_verifier", pending.verifier),
        ]
        let basic = configuration.clientSecret.map { (user: configuration.clientID, password: $0) }
        if basic == nil { fields.append(("client_id", configuration.clientID)) }

        let answer: (status: Int, body: Data)
        do {
            answer = try await poster.postForm(
                metadata.tokenEndpoint, fields: fields, basicAuthorization: basic)
        } catch let error as OIDCSignInError {
            throw error
        } catch {
            throw OIDCSignInError.tokenExchange("\(error)")
        }
        guard (200..<300).contains(answer.status) else {
            let reason = (try? JSONDecoder().decode(TokenErrorResponse.self, from: answer.body))?
                .error
            throw OIDCSignInError.tokenExchange(
                "HTTP \(answer.status)\(reason.map { ": \($0)" } ?? "")")
        }
        guard let tokens = try? JSONDecoder().decode(TokenResponse.self, from: answer.body),
            let idToken = tokens.idToken
        else {
            throw OIDCSignInError.tokenExchange("response carried no id_token")
        }

        let principal: Principal
        do {
            principal = try await validator.validate(idToken)
        } catch {
            throw OIDCSignInError.invalidIDToken("\(error)")
        }
        // The nonce binds this ID token to this browser's sign-in, so one
        // issued for another session cannot be substituted.
        guard principal.claim("nonce", as: String.self) == pending.nonce else {
            throw OIDCSignInError.invalidIDToken("nonce does not match")
        }
        return SignInResult(principal: principal, returnTo: pending.returnTo)
    }

    // MARK: Sign out

    /// RP-initiated logout (OpenID Connect RP-Initiated Logout 1.0), by
    /// `client_id` rather than `id_token_hint`, since no token is kept. A
    /// provider without an end-session endpoint signs out locally only.
    public func beginSignOut(_ context: RequestContext) async throws -> SignOutStep {
        guard let endpoint = try await metadata.metadata().endSessionEndpoint,
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        else { return .done }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "client_id", value: configuration.clientID))
        if let postLogout = configuration.postLogoutRedirectURI {
            items.append(
                URLQueryItem(name: "post_logout_redirect_uri", value: postLogout.absoluteString))
        }
        components.queryItems = items
        return components.url.map(SignOutStep.redirect) ?? .done
    }

    // MARK: PKCE and randomness

    /// 32 random bytes, base64url — 256 bits, the length RFC 7636 recommends
    /// for a verifier and more than `state` and `nonce` need.
    static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    /// `BASE64URL(SHA256(ASCII(code_verifier)))` — RFC 7636 §4.2.
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private struct TokenResponse: Decodable {
        let idToken: String?
        enum CodingKeys: String, CodingKey { case idToken = "id_token" }
    }

    private struct TokenErrorResponse: Decodable {
        let error: String
    }
}

/// A sign-in that has been sent to the provider and not yet come back,
/// held in the session. Several may be open at once — two tabs — so they are
/// kept by `state`, bounded, and expire.
struct PendingSignIn: Codable, Equatable {
    let state: String
    let nonce: String
    let verifier: String
    let returnTo: String?
    let startedAt: Date

    static let sessionKey = "flight.oidc.pending"
    /// Enough for a handful of tabs; past it the oldest is dropped.
    static let maximumOpen = 5

    static func store(_ pending: PendingSignIn, in session: Session, now: Date, lifetime: Duration)
        throws
    {
        var open = live(
            try session.get(sessionKey, as: [PendingSignIn].self) ?? [], now: now,
            lifetime: lifetime)
        open.append(pending)
        if open.count > maximumOpen { open.removeFirst(open.count - maximumOpen) }
        try session.set(sessionKey, open)
    }

    static func take(state: String, from session: Session, now: Date, lifetime: Duration) throws
        -> PendingSignIn?
    {
        let open = live(
            try session.get(sessionKey, as: [PendingSignIn].self) ?? [], now: now,
            lifetime: lifetime)
        let match = open.first { $0.state == state }
        let remaining = open.filter { $0.state != state }
        if remaining.isEmpty {
            session.remove(sessionKey)
        } else {
            try session.set(sessionKey, remaining)
        }
        return match
    }

    private static func live(_ open: [PendingSignIn], now: Date, lifetime: Duration)
        -> [PendingSignIn]
    {
        let seconds = Double(lifetime.components.seconds)
        return open.filter { now.timeIntervalSince($0.startedAt) < seconds }
    }
}

/// Why an OIDC sign-in failed. The wire sees a generic answer; the case and
/// its detail are for the log.
public enum OIDCSignInError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Configuration that cannot work — caught at composition.
    case configuration(String)
    /// The discovery document could not be fetched or trusted.
    case discovery(String)
    /// The provider sent the browser back with an error — often the user
    /// declining consent.
    case providerRefused(String)
    /// The callback was missing parts, or named a sign-in this session never
    /// started or has already finished.
    case invalidCallback(String)
    /// The code could not be exchanged.
    case tokenExchange(String)
    /// The ID token failed validation or did not match this sign-in.
    case invalidIDToken(String)

    public var description: String {
        switch self {
        case .configuration(let detail): "OIDC sign-in misconfigured: \(detail)"
        case .discovery(let detail): "OIDC discovery failed: \(detail)"
        case .providerRefused(let code): "the provider refused the sign-in: \(code)"
        case .invalidCallback(let detail): "invalid sign-in callback: \(detail)"
        case .tokenExchange(let detail): "token exchange failed: \(detail)"
        case .invalidIDToken(let detail): "ID token rejected: \(detail)"
        }
    }
}

extension OIDCSignInError: HTTPErrorRepresentable {
    public var httpStatus: HTTPResponse.Status {
        switch self {
        case .configuration, .discovery, .tokenExchange: .badGateway
        case .providerRefused, .invalidCallback, .invalidIDToken: .unauthorized
        }
    }

    public var httpMessage: String {
        switch self {
        case .configuration, .discovery, .tokenExchange: "Sign-in provider unavailable"
        case .providerRefused, .invalidCallback, .invalidIDToken: "Sign-in failed"
        }
    }
}
