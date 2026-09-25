import AlulaWeb
import Crypto
import Foundation
import HTTPTypes

/// Checks that an incoming webhook was signed by the sender that holds the
/// shared secret, before the handler trusts a byte of it.
///
/// Build it where the application is composed, so a missing or malformed
/// secret stops the start instead of failing every webhook later:
///
/// ```swift
/// struct WebhooksModule: AlulaModule {
///     let middleware: [MiddlewareRegistration]
///
///     init(configuration: Configuration) throws {
///         let secret = try configuration.getIfPresent("stripe.webhook-secret", as: String.self)
///         let stripe = try WebhookSignature.stripe(secrets: [secret ?? ""])
///         middleware = MiddlewareRegistration.lane("stripe", [VerifyWebhookSignature(stripe)])
///     }
/// }
///
/// @PostRoute("/webhooks/stripe", pipelines: [.default, "stripe"])
/// func stripe(_ context: RequestContext) async throws -> Response { … }
/// ```
///
/// Or call ``verify(_:)`` from a handler that holds one.
///
/// - **HMAC-SHA256 over the exact bytes received**, compared in constant
///   time. Verify before decoding, never after re-encoding: a re-encoded
///   body is not the body that was signed.
/// - **Several secrets.** Pass the old and the new one while rotating, and
///   either signature is accepted.
/// - **Replay window.** Schemes that sign a timestamp (Stripe, Standard
///   Webhooks) refuse one older or newer than `tolerance`, five minutes by
///   default, so a captured request cannot be replayed next week.
/// - **One answer.** Every failure is a `401` saying only that the
///   signature did not verify.
///
/// The route must buffer its body, which is the default. A streaming body
/// (`body: RequestBodyStream`) is not in `context.request.body` to verify.
public struct WebhookSignature: Sendable {
    enum Scheme: Sendable {
        /// `header: <prefix><hex or base64 of HMAC(body)>`.
        case simple(header: HTTPField.Name, prefix: String, base64: Bool)
        /// `Stripe-Signature: t=<unix>,v1=<hex HMAC("t.body")>[,v1=…]`.
        case stripe(tolerance: Duration)
        /// `webhook-id`, `webhook-timestamp`,
        /// `webhook-signature: v1,<base64 HMAC("id.ts.body")> …`.
        case standardWebhooks(tolerance: Duration)
    }

    let scheme: Scheme
    let keys: [SymmetricKey]
    let now: @Sendable () -> Date

    init(scheme: Scheme, keys: [SymmetricKey], now: @escaping @Sendable () -> Date) throws {
        guard !keys.isEmpty else { throw WebhookConfigurationError.noSecrets }
        self.scheme = scheme
        self.keys = keys
        self.now = now
    }

    /// GitHub: `X-Hub-Signature-256: sha256=<hex>`.
    public static func github(secrets: [String]) throws -> WebhookSignature {
        try WebhookSignature(
            scheme: .simple(
                header: HTTPField.Name("X-Hub-Signature-256")!, prefix: "sha256=", base64: false),
            keys: try plainKeys(secrets), now: Date.init)
    }

    /// Stripe: `Stripe-Signature: t=…,v1=…`, signing `"<t>.<body>"`.
    public static func stripe(
        secrets: [String], tolerance: Duration = .seconds(300),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws -> WebhookSignature {
        try WebhookSignature(
            scheme: .stripe(tolerance: tolerance), keys: try plainKeys(secrets), now: now)
    }

    /// Standard Webhooks (standardwebhooks.com; Svix, Resend and others).
    /// Secrets are given as issued, `whsec_<base64>`; the `whsec_` is
    /// optional.
    ///
    /// - Throws: ``WebhookConfigurationError`` for a secret that is not valid
    ///   base64. Using its bytes as they are instead would start the
    ///   application with a key no sender signs with, and every webhook
    ///   would fail its check for as long as it ran.
    public static func standardWebhooks(
        secrets: [String], tolerance: Duration = .seconds(300),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws -> WebhookSignature {
        let keys = try secrets.enumerated().map { index, secret in
            let encoded = secret.hasPrefix("whsec_") ? String(secret.dropFirst(6)) : secret
            guard let data = Data(base64Encoded: encoded), !data.isEmpty else {
                throw WebhookConfigurationError.invalidSecret(index: index)
            }
            return SymmetricKey(data: data)
        }
        return try WebhookSignature(
            scheme: .standardWebhooks(tolerance: tolerance), keys: keys, now: now)
    }

    /// Any sender that puts an HMAC-SHA256 of the body in one header.
    ///
    /// - Parameters:
    ///   - header: Where the signature arrives.
    ///   - prefix: What precedes it, such as `sha256=`; empty for nothing.
    ///   - base64: Whether it is base64 rather than hex.
    ///   - secrets: The shared secrets, as the sender shows them.
    public static func hmacSHA256(
        header: HTTPField.Name, prefix: String = "", base64: Bool = false, secrets: [String]
    ) throws -> WebhookSignature {
        try WebhookSignature(
            scheme: .simple(header: header, prefix: prefix, base64: base64),
            keys: try plainKeys(secrets), now: Date.init)
    }

    private static func plainKeys(_ secrets: [String]) throws -> [SymmetricKey] {
        try secrets.enumerated().map { index, secret in
            guard !secret.isEmpty else {
                throw WebhookConfigurationError.invalidSecret(index: index)
            }
            return SymmetricKey(data: Data(secret.utf8))
        }
    }

    /// Throws a `401` unless the request carries a valid signature.
    public func verify(_ context: RequestContext) throws {
        guard isValid(context.request) else {
            context.logger.info("webhook signature did not verify")
            throw HTTPError(.unauthorized, "Webhook signature did not verify")
        }
    }

    func isValid(_ request: Request) -> Bool {
        let body = request.body
        switch scheme {
        case .simple(let header, let prefix, let base64):
            guard let value = request.headers[header], value.hasPrefix(prefix),
                let signature = decode(String(value.dropFirst(prefix.count)), base64: base64)
            else { return false }
            return matches(signature, over: body)

        case .stripe(let tolerance):
            guard let value = request.headers[HTTPField.Name("Stripe-Signature")!] else {
                return false
            }
            var timestamp: String?
            var signatures: [Data] = []
            for part in value.split(separator: ",") {
                let pair = part.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard pair.count == 2 else { continue }
                if pair[0] == "t" { timestamp = pair[1] }
                if pair[0] == "v1", let signature = decode(pair[1], base64: false) {
                    signatures.append(signature)
                }
            }
            guard let timestamp, isFresh(timestamp, tolerance: tolerance) else { return false }
            let signed = Data((timestamp + ".").utf8) + body
            return signatures.contains { matches($0, over: signed) }

        case .standardWebhooks(let tolerance):
            guard let id = request.headers[HTTPField.Name("webhook-id")!],
                let timestamp = request.headers[HTTPField.Name("webhook-timestamp")!],
                let value = request.headers[HTTPField.Name("webhook-signature")!],
                isFresh(timestamp, tolerance: tolerance)
            else { return false }
            let signed = Data("\(id).\(timestamp).".utf8) + body
            return value.split(separator: " ").contains { entry in
                let parts = entry.split(separator: ",", maxSplits: 1)
                guard parts.count == 2, parts[0] == "v1",
                    let signature = decode(String(parts[1]), base64: true)
                else { return false }
                return matches(signature, over: signed)
            }
        }
    }

    private func matches(_ signature: Data, over payload: Data) -> Bool {
        keys.contains { key in
            HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: payload, using: key)
        }
    }

    private func isFresh(_ timestamp: String, tolerance: Duration) -> Bool {
        guard let seconds = TimeInterval(timestamp) else { return false }
        return abs(now().timeIntervalSince1970 - seconds) <= Double(tolerance.components.seconds)
    }

    private func decode(_ text: String, base64: Bool) -> Data? {
        if base64 { return Data(base64Encoded: text) }
        guard text.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}

/// A webhook secret that cannot be used, found when the signature is built:
/// at composition, when that is where it is built.
public enum WebhookConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No secrets were given.
    case noSecrets
    /// The secret at this position is empty, or for Standard Webhooks not
    /// valid base64. The value itself is never repeated.
    case invalidSecret(index: Int)

    public var description: String {
        switch self {
        case .noSecrets: "a webhook signature needs at least one secret"
        case .invalidSecret(let index):
            "webhook secret #\(index + 1) is empty or not in the sender's format"
        }
    }
}

/// Verifies a ``WebhookSignature`` for every route on the lane it is put in.
///
/// ```swift
/// let middleware = MiddlewareRegistration.lane(
///     "github-webhooks", [VerifyWebhookSignature(try .github(secrets: [secret]))])
/// ```
public struct VerifyWebhookSignature: Middleware {
    let signature: WebhookSignature

    public init(_ signature: WebhookSignature) {
        self.signature = signature
    }

    public func handle(_ context: RequestContext, next: Next) async throws -> Response {
        try signature.verify(context)
        return try await next(context)
    }
}
