import AlulaCore
import AlulaSupport
import AlulaSupportFoundation
import Foundation
import HTTPTypes

/// `http-client.client-credentials.*`: a service account at an OAuth 2.0
/// authorization server (Keycloak, Auth0, Entra, …).
///
/// ```yaml
/// http-client:
///   client-credentials:
///     issuer: https://id.example.com/realms/main   # or token-url
///     client-id: billing-worker
///     client-secret: ${BILLING_CLIENT_SECRET}
///     scope: invoices:write                        # optional
///     audience: https://api.example.com            # optional
///     client-authentication: basic                 # basic | post
/// ```
public struct ClientCredentialsSettings: Sendable, Equatable {
    /// How the client proves its identity at the token endpoint: HTTP Basic
    /// (RFC 6749 §2.3.1's recommendation, and the default) or the form body.
    public enum ClientAuthentication: String, Sendable, Equatable {
        /// `Authorization: Basic`, id and secret percent-encoded first.
        case basic
        /// `client_id` and `client_secret` in the form body.
        case post
    }

    /// Where tokens come from.
    public enum Endpoint: Sendable, Equatable {
        /// The token endpoint itself.
        case tokenURL(URL)
        /// An OpenID Connect issuer; the token endpoint is discovered from
        /// `<issuer>/.well-known/openid-configuration`.
        case issuer(URL)
    }

    /// The token endpoint, or the issuer to discover it from.
    public var endpoint: Endpoint
    /// The service account's client id.
    public var clientID: String
    /// Its secret. Never logged, and not in any error's description.
    public var clientSecret: String
    /// The `scope` form field, sent when set.
    public var scope: String?
    /// The `audience` form field (Auth0 and others), sent when set.
    public var audience: String?
    /// How the id and secret are presented.
    public var clientAuthentication: ClientAuthentication
    /// A token is renewed this long before it expires, so a request never
    /// leaves with one that lapses on the way. Fractions of a second count.
    /// Not read from configuration.
    public var renewBefore: Duration

    /// Settings built in code. Nothing is checked or fetched here.
    public init(
        endpoint: Endpoint, clientID: String, clientSecret: String, scope: String? = nil,
        audience: String? = nil, clientAuthentication: ClientAuthentication = .basic,
        renewBefore: Duration = .seconds(30)
    ) {
        self.endpoint = endpoint
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scope = scope
        self.audience = audience
        self.clientAuthentication = clientAuthentication
        self.renewBefore = renewBefore
    }

    /// Reads the keys above under `prefix`. Throws
    /// ``ClientCredentialsConfigurationError`` when both or neither of
    /// `token-url` and `issuer` are set, either is not an http(s) URL, the
    /// client id or secret is missing or empty, or `client-authentication`
    /// is not `basic` or `post`. Nothing is fetched here.
    public init(configuration: Configuration, prefix: String = "http-client.client-credentials")
        throws
    {
        func key(_ name: String) -> String { "\(prefix).\(name)" }
        func url(_ name: String) throws -> URL? {
            guard let raw = try configuration.getIfPresent(key(name), as: String.self) else {
                return nil
            }
            guard let url = URL(string: raw), url.scheme == "https" || url.scheme == "http" else {
                throw ClientCredentialsConfigurationError(
                    "\(key(name)) is not an http(s) URL: \(raw)")
            }
            return url
        }
        let endpoint: Endpoint
        switch (try url("token-url"), try url("issuer")) {
        case (let token?, nil): endpoint = .tokenURL(token)
        case (nil, let issuer?): endpoint = .issuer(issuer)
        case (_?, _?):
            throw ClientCredentialsConfigurationError(
                "set one of \(key("token-url")) and \(key("issuer")), not both")
        case (nil, nil):
            throw ClientCredentialsConfigurationError(
                "\(key("token-url")) or \(key("issuer")) is required")
        }
        guard let clientID = try configuration.getIfPresent(key("client-id"), as: String.self),
            !clientID.isEmpty
        else { throw ClientCredentialsConfigurationError("\(key("client-id")) is required") }
        guard let secret = try configuration.getIfPresent(key("client-secret"), as: String.self),
            !secret.isEmpty
        else { throw ClientCredentialsConfigurationError("\(key("client-secret")) is required") }
        let rawAuthentication =
            try configuration.getIfPresent(key("client-authentication"), as: String.self) ?? "basic"
        guard let authentication = ClientAuthentication(rawValue: rawAuthentication.lowercased())
        else {
            throw ClientCredentialsConfigurationError(
                "\(key("client-authentication")) must be basic or post; it is \(rawAuthentication)")
        }
        self.init(
            endpoint: endpoint, clientID: clientID, clientSecret: secret,
            scope: try configuration.getIfPresent(key("scope"), as: String.self),
            audience: try configuration.getIfPresent(key("audience"), as: String.self),
            clientAuthentication: authentication)
    }
}

/// An `http-client.client-credentials.*` value that cannot be used. Thrown
/// at composition.
public struct ClientCredentialsConfigurationError: Error, Sendable, CustomStringConvertible,
    ModuleConfigurationError
{
    /// Names the key and what is wrong with it.
    public let description: String
    init(_ description: String) { self.description = description }
}

/// A token could not be had. Never carries the client secret.
public enum ClientCredentialsError: Error, Sendable, CustomStringConvertible, TemporarilyUnavailable
{
    /// The authorization server said no (a non-2xx below 500) — usually configuration: a
    /// wrong secret (`invalid_client`), a scope the client may not have
    /// (`invalid_scope`). Retrying will not help. A 429 that outlasts the
    /// HTTP client's own retries also lands here.
    case refused(
        endpoint: String, clientID: String, status: Int, error: String?, errorDescription: String?)
    /// The authorization server could not be reached, timed out, or failed
    /// (5xx), or OpenID discovery answered anything but 2xx. The only case
    /// that is `TemporarilyUnavailable`, with a `retryAfter` of 5 seconds.
    case unavailable(endpoint: String, reason: String)
    /// An answer that is not a token response.
    case malformed(endpoint: String, reason: String)

    /// The endpoint (query and credentials removed), the client id, and
    /// what went wrong. Never the secret.
    public var description: String {
        switch self {
        case .refused(let endpoint, let clientID, let status, let error, let errorDescription):
            let why = [error, errorDescription].compactMap { $0 }.joined(separator: ": ")
            return "the token endpoint \(endpoint) refused client '\(clientID)' (\(status))"
                + (why.isEmpty ? "" : ": \(why)")
        case .unavailable(let endpoint, let reason):
            return "the token endpoint \(endpoint) is unavailable: \(reason)"
        case .malformed(let endpoint, let reason):
            return
                "the token endpoint \(endpoint) answered something that is not a token: \(reason)"
        }
    }

    /// True only for ``unavailable(endpoint:reason:)``.
    public var isTemporarilyUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }

    /// Five seconds when temporarily unavailable; otherwise nil.
    public var retryAfter: Duration? { isTemporarilyUnavailable ? .seconds(5) : nil }
}

/// Access tokens for one service account, by the OAuth 2.0 client
/// credentials grant (RFC 6749 §4.4), cached until shortly before they
/// expire.
///
/// A service calling another Alula service used to write this by hand —
/// Relay's gateway did: the token request, the cache, renewal before expiry,
/// renewal after a 401 (Relay #31). Callers asking at once share one
/// request to the token endpoint.
///
/// ```swift
/// let tokens = ClientCredentialsTokenSource(settings: settings, http: httpClient)
/// let core = AuthorizedHTTPClient(http: httpClient, tokens: tokens)
/// let response = try await core.send(OutboundRequest(url: invoicesURL))
/// ```
public actor ClientCredentialsTokenSource {
    /// The service account and endpoint.
    public let settings: ClientCredentialsSettings
    private let http: OutboundHTTPClient
    private let now: @Sendable () -> Date
    private var current: (token: String, expires: Date)?
    private var inFlight: Task<(token: String, expires: Date), any Error>?
    private var tokenURL: URL?

    /// A source that fetches through `http` on first use; nothing is fetched
    /// here. `now` is the clock token expiry is judged by.
    public init(
        settings: ClientCredentialsSettings, http: OutboundHTTPClient,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.settings = settings
        self.http = http
        self.now = now
        if case .tokenURL(let url) = settings.endpoint { self.tokenURL = url }
    }

    /// A token valid for at least `renewBefore`, fetching one if needed.
    ///
    /// Callers that arrive while a fetch is in flight wait for it and share
    /// its token or its error. A failed fetch is not cached: the next call
    /// tries again. Inside the renewal margin, a failure throws even though
    /// the cached token has not yet expired; it is not handed out as a
    /// fallback. The token request goes through the HTTP client marked
    /// idempotent, so the client's retries apply to it.
    ///
    /// - Throws: ``ClientCredentialsError``.
    public func token() async throws -> String {
        if let current, current.expires.timeIntervalSince(now()) > settings.renewBefore.inSeconds {
            return current.token
        }
        if let inFlight { return try await inFlight.value.token }
        let task = Task { try await self.fetch() }
        inFlight = task
        defer { inFlight = nil }
        let fetched = try await task.value
        current = fetched
        return fetched.token
    }

    /// Forgets `token` — the service it was sent to refused it (401) — so the
    /// next ``token()`` fetches another. A newer token is kept.
    public func invalidate(_ token: String) {
        if current?.token == token { current = nil }
    }

    private func fetch() async throws -> (token: String, expires: Date) {
        let endpoint = try await resolveTokenURL()
        let label = endpoint.redactedForLog
        var form = [("grant_type", "client_credentials")]
        if let scope = settings.scope { form.append(("scope", scope)) }
        if let audience = settings.audience { form.append(("audience", audience)) }
        var headers = HTTPFields()
        headers[.contentType] = "application/x-www-form-urlencoded"
        headers[.accept] = "application/json"
        switch settings.clientAuthentication {
        case .basic:
            headers[.authorization] = FormEncoding.basicAuthorization(
                user: settings.clientID, password: settings.clientSecret)
        case .post:
            form += [("client_id", settings.clientID), ("client_secret", settings.clientSecret)]
        }
        let body = FormEncoding.encode(form)
        let response: OutboundResponse
        do {
            response = try await http.send(
                OutboundRequest(
                    method: .post, url: endpoint, headers: headers, body: Data(body.utf8),
                    idempotent: true))
        } catch {
            throw ClientCredentialsError.unavailable(endpoint: label, reason: "\(error)")
        }
        let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        if response.status.kind == .serverError {
            throw ClientCredentialsError.unavailable(
                endpoint: label, reason: "answered \(response.status.code)")
        }
        guard response.status.kind == .successful else {
            throw ClientCredentialsError.refused(
                endpoint: label, clientID: settings.clientID, status: response.status.code,
                error: json?["error"] as? String,
                errorDescription: json?["error_description"] as? String)
        }
        guard let token = json?["access_token"] as? String, !token.isEmpty else {
            throw ClientCredentialsError.malformed(endpoint: label, reason: "no access_token")
        }
        // Without expires_in, a minute: long enough to be useful, short
        // enough that a token the server meant to be brief is not kept.
        let lifetime = (json?["expires_in"] as? Double) ?? 60
        return (token, now().addingTimeInterval(lifetime))
    }

    private func resolveTokenURL() async throws -> URL {
        if let tokenURL { return tokenURL }
        let issuer: URL
        switch settings.endpoint {
        case .tokenURL(let url): return url
        case .issuer(let url): issuer = url
        }
        let discovery = issuer.appendingPathComponent(".well-known/openid-configuration")
        let label = discovery.redactedForLog
        let response: OutboundResponse
        do {
            response = try await http.send(OutboundRequest(url: discovery))
        } catch {
            throw ClientCredentialsError.unavailable(endpoint: label, reason: "\(error)")
        }
        guard response.status.kind == .successful else {
            throw ClientCredentialsError.unavailable(
                endpoint: label, reason: "discovery answered \(response.status.code)")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
            let raw = json["token_endpoint"] as? String, let url = URL(string: raw)
        else {
            throw ClientCredentialsError.malformed(endpoint: label, reason: "no token_endpoint")
        }
        tokenURL = url
        return url
    }
}

/// An ``OutboundHTTPClient`` that sends a service account's bearer token,
/// and on a `401` fetches a new one and tries once more.
///
/// That one resend happens for every method, `POST` included, on the
/// reading that a request answered 401 was not acted on. It is separate
/// from, and on top of, the client's own retries.
public struct AuthorizedHTTPClient: Sendable {
    /// The client requests go through, with its retry policy.
    public let http: OutboundHTTPClient
    /// Where the bearer tokens come from.
    public let tokens: ClientCredentialsTokenSource

    /// A client sending through `http` with tokens from `tokens`.
    public init(http: OutboundHTTPClient, tokens: ClientCredentialsTokenSource) {
        self.http = http
        self.tokens = tokens
    }

    /// Sends `request` with `Authorization: Bearer`, replacing any
    /// `Authorization` header it carried. Throws ``ClientCredentialsError``
    /// when no token can be had, including the fresh one after a 401;
    /// otherwise as ``OutboundHTTPClient/send(_:)``.
    public func send(_ request: OutboundRequest) async throws -> OutboundResponse {
        var request = request
        var token = try await tokens.token()
        request.headers[.authorization] = "Bearer \(token)"
        let response = try await http.send(request)
        guard response.status == .unauthorized else { return response }
        // A token revoked, or signed with a key since rotated: once more
        // with a fresh one. A second 401 is the answer.
        await tokens.invalidate(token)
        token = try await tokens.token()
        request.headers[.authorization] = "Bearer \(token)"
        return try await http.send(request)
    }
}

/// A service account's tokens and an authorized client, from
/// `http-client.client-credentials.*`, over the application's HTTP client.
public struct AlulaClientCredentialsModule: AlulaModule {
    /// The service account's tokens, for a caller that attaches them itself.
    public let tokenSource: ClientCredentialsTokenSource
    /// The application's HTTP client with the tokens attached.
    public let authorizedHTTPClient: AuthorizedHTTPClient

    /// The composition root's initializer. `httpClient` is
    /// `AlulaHTTPClientModule`'s.
    ///
    /// - Throws: ``ClientCredentialsConfigurationError``; nothing is fetched
    ///   until the first token is asked for.
    public init(configuration: Configuration, httpClient: OutboundHTTPClient) throws {
        let tokens = ClientCredentialsTokenSource(
            settings: try ClientCredentialsSettings(configuration: configuration), http: httpClient)
        self.tokenSource = tokens
        self.authorizedHTTPClient = AuthorizedHTTPClient(http: httpClient, tokens: tokens)
    }

    /// Traps: this module needs its configuration and the HTTP client.
    /// Compose with `alulaComposeModules`.
    public init() {
        preconditionFailure(
            "AlulaClientCredentialsModule takes its configuration and the HTTP client in "
                + "init(configuration:httpClient:), so it cannot be instantiated from its type. "
                + "Pass `composedBy: alulaComposeModules` to Alula.run.")
    }
}
