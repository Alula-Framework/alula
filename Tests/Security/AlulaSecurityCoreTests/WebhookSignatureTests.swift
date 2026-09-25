import AlulaWeb
import AlulaWebTesting
import Crypto
import Foundation
import HTTPTypes
import Testing

@testable import AlulaSecurityCore

@Suite("Webhook signatures")
struct WebhookSignatureTests {
    let body = Data(#"{"id":"evt_1","type":"invoice.paid"}"#.utf8)
    let secret = "s3cr3t"

    private func hmac(_ payload: Data, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: key)))
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private func request(_ headers: HTTPFields, body: Data? = nil) -> Request {
        Request(method: .post, path: "/hook", headers: headers, body: body ?? self.body)
    }

    @Test("GitHub: the right secret passes, another secret or a changed body does not")
    func github() throws {
        let good = "sha256=" + hex(hmac(body, key: Data(secret.utf8)))
        let name = HTTPField.Name("X-Hub-Signature-256")!
        #expect(try WebhookSignature.github(secrets: [secret]).isValid(request([name: good])))
        #expect(try !WebhookSignature.github(secrets: ["other"]).isValid(request([name: good])))
        #expect(
            try !WebhookSignature.github(secrets: [secret]).isValid(
                request([name: good], body: Data("{}".utf8))))
        #expect(try !WebhookSignature.github(secrets: [secret]).isValid(request([:])))
    }

    @Test("rotation: either of two secrets is accepted")
    func rotation() throws {
        let name = HTTPField.Name("X-Hub-Signature-256")!
        let signedWithOld = "sha256=" + hex(hmac(body, key: Data("old".utf8)))
        #expect(
            try WebhookSignature.github(secrets: ["new", "old"]).isValid(
                request([name: signedWithOld]))
        )
    }

    @Test("Stripe: signs t.body, and a stale timestamp is refused")
    func stripe() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let t = "1800000000"
        let v1 = hex(hmac(Data((t + ".").utf8) + body, key: Data(secret.utf8)))
        let header = HTTPField.Name("Stripe-Signature")!
        let fresh = try WebhookSignature.stripe(secrets: [secret], now: { now })
        #expect(fresh.isValid(request([header: "t=\(t),v1=deadbeef,v1=\(v1)"])))
        let later = try WebhookSignature.stripe(
            secrets: [secret], now: { now.addingTimeInterval(301) })
        #expect(!later.isValid(request([header: "t=\(t),v1=\(v1)"])))
    }

    @Test("Standard Webhooks: signs id.timestamp.body with the decoded whsec_ key")
    func standardWebhooks() throws {
        let key = Data("0123456789abcdef0123456789abcdef".utf8)
        let secretText = "whsec_" + key.base64EncodedString()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let signature = hmac(Data("msg_1.1800000000.".utf8) + body, key: key).base64EncodedString()
        let headers: HTTPFields = [
            HTTPField.Name("webhook-id")!: "msg_1",
            HTTPField.Name("webhook-timestamp")!: "1800000000",
            HTTPField.Name("webhook-signature")!: "v1,bm9wZQ== v1,\(signature)",
        ]
        #expect(
            try WebhookSignature.standardWebhooks(secrets: [secretText], now: { now }).isValid(
                request(headers)))
        #expect(
            try !WebhookSignature.standardWebhooks(
                secrets: ["whsec_" + Data("wrong".utf8).base64EncodedString()], now: { now }
            )
            .isValid(request(headers)))
    }

    @Test("the middleware answers 401 and never reaches the handler")
    func middleware() async throws {
        let route = RouteRegistration(method: .post, path: "/hook", source: "t") { _ in
            .text("handled")
        }
        let client = try TestClient(
            routes: [route],
            middleware: MiddlewareRegistration.lane(
                .default, [VerifyWebhookSignature(try .github(secrets: [secret]))]))
        let refused = await client.post("/hook", body: body)
        #expect(refused.status == .unauthorized)
        let good = "sha256=" + hex(hmac(body, key: Data(secret.utf8)))
        let accepted = await client.post(
            "/hook", headers: [HTTPField.Name("X-Hub-Signature-256")!: good], body: body)
        #expect(accepted.bodyText == "handled")
    }

    @Test("unusable secrets fail when the signature is built, never silently")
    func configurationErrors() {
        #expect(throws: WebhookConfigurationError.noSecrets) {
            try WebhookSignature.github(secrets: [])
        }
        #expect(throws: WebhookConfigurationError.invalidSecret(index: 0)) {
            try WebhookSignature.stripe(secrets: [""])
        }
        // A typo that makes the value not base64 used to become its UTF-8
        // bytes: a key no sender signs with.
        #expect(throws: WebhookConfigurationError.invalidSecret(index: 1)) {
            try WebhookSignature.standardWebhooks(secrets: [
                "whsec_" + Data("ok".utf8).base64EncodedString(), "whsec_not base64!",
            ])
        }
    }
}
