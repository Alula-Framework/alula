import AsyncHTTPClient
import Foundation
import NIOCore
import NIOFoundationCompat
import Synchronization

/// The endpoints an OpenID provider publishes in its discovery document —
/// the part of it a sign-in needs.
struct OIDCProviderMetadata: Decodable, Sendable, Equatable {
    let issuer: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let endSessionEndpoint: URL?
    let userinfoEndpoint: URL?
    let codeChallengeMethodsSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case endSessionEndpoint = "end_session_endpoint"
        case userinfoEndpoint = "userinfo_endpoint"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
    }
}

/// Fetches and caches the discovery document, holding it to the same
/// transport policy as the key fetch: every endpoint it names either sees
/// the user's authorization code or decides where their browser goes.
final class OIDCMetadataSource: Sendable {
    private let issuer: String
    private let http: any HTTPGetting
    private let policy: JWKSTransportPolicy
    private let cached = Mutex<OIDCProviderMetadata?>(nil)

    init(issuer: String, http: any HTTPGetting, policy: JWKSTransportPolicy) {
        self.issuer = issuer
        self.http = http
        self.policy = policy
    }

    func metadata() async throws -> OIDCProviderMetadata {
        if let metadata = cached.withLock({ $0 }) { return metadata }
        let base = issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer
        guard let url = URL(string: base + "/.well-known/openid-configuration") else {
            throw OIDCSignInError.discovery("issuer is not a URL: \(issuer)")
        }
        do {
            try policy.validate(url, what: "the OIDC discovery endpoint")
            let data = try await http.getJSON(url)
            let metadata = try JSONDecoder().decode(OIDCProviderMetadata.self, from: data)
            // Discovery §4.3: the document must assert the issuer asked about.
            guard Self.normalized(metadata.issuer) == Self.normalized(issuer) else {
                throw OIDCSignInError.discovery(
                    "document issuer \"\(metadata.issuer)\" does not match \"\(issuer)\"")
            }
            try policy.validate(metadata.authorizationEndpoint, what: "the authorization endpoint")
            try policy.validate(metadata.tokenEndpoint, what: "the token endpoint")
            if let endSession = metadata.endSessionEndpoint {
                try policy.validate(endSession, what: "the end-session endpoint")
            }
            if let userinfo = metadata.userinfoEndpoint {
                // It receives the access token.
                try policy.validate(userinfo, what: "the UserInfo endpoint")
            }
            cached.withLock { $0 = metadata }
            return metadata
        } catch let error as OIDCSignInError {
            throw error
        } catch {
            throw OIDCSignInError.discovery("\(error)")
        }
    }

    private static func normalized(_ issuer: String) -> String {
        issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer
    }
}

/// The two calls a sign-in makes with credentials: the token exchange, and
/// the one UserInfo request the access token is spent on.
protocol HTTPFormPosting: Sendable {
    func postForm(
        _ url: URL, fields: [(String, String)],
        basicAuthorization: (user: String, password: String)?
    ) async throws -> (status: Int, body: Data)

    func getWithBearer(_ url: URL, token: String) async throws -> (status: Int, body: Data)
}

struct AsyncHTTPFormPoster: HTTPFormPosting {
    /// A token response is small; anything past this is not one.
    static let maxResponseBytes = 1_048_576

    let timeout: Duration
    let policy: JWKSTransportPolicy

    func postForm(
        _ url: URL, fields: [(String, String)],
        basicAuthorization: (user: String, password: String)?
    ) async throws -> (status: Int, body: Data) {
        try policy.validate(url, what: "the token endpoint")
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/x-www-form-urlencoded")
        request.headers.add(name: "Accept", value: "application/json")
        if let basicAuthorization {
            // RFC 6749 §2.3.1: each half is form-encoded before the pair is
            // base64'd — a secret containing ':' or '%' is otherwise misread.
            let pair =
                FormEncoding.encode(basicAuthorization.user) + ":"
                + FormEncoding.encode(basicAuthorization.password)
            request.headers.add(
                name: "Authorization", value: "Basic " + Data(pair.utf8).base64EncodedString())
        }
        request.body = .bytes(ByteBuffer(string: FormEncoding.encode(fields)))
        let response = try await HTTPClient.shared.execute(request, timeout: TimeAmount(timeout))
        for hop in response.history {
            guard let hopURL = URL(string: hop.request.url) else {
                throw OIDCSignInError.tokenExchange("unparseable redirect target")
            }
            try policy.validate(hopURL, what: "a redirect during the token exchange")
        }
        let body = try await response.body.collect(upTo: Self.maxResponseBytes)
        return (Int(response.status.code), Data(buffer: body))
    }

    func getWithBearer(_ url: URL, token: String) async throws -> (status: Int, body: Data) {
        try policy.validate(url, what: "the UserInfo endpoint")
        var request = HTTPClientRequest(url: url.absoluteString)
        request.headers.add(name: "Authorization", value: "Bearer \(token)")
        request.headers.add(name: "Accept", value: "application/json")
        let response = try await HTTPClient.shared.execute(request, timeout: TimeAmount(timeout))
        for hop in response.history {
            guard let hopURL = URL(string: hop.request.url) else {
                throw OIDCSignInError.userInfo("unparseable redirect target")
            }
            try policy.validate(hopURL, what: "a redirect during the UserInfo request")
        }
        let body = try await response.body.collect(upTo: Self.maxResponseBytes)
        return (Int(response.status.code), Data(buffer: body))
    }
}

/// `application/x-www-form-urlencoded`, as RFC 6749 and the WHATWG URL
/// standard write it: unreserved characters as-is, everything else
/// percent-encoded.
enum FormEncoding {
    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics.intersection(
            CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    static func encode(_ fields: [(String, String)]) -> String {
        fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }
}
