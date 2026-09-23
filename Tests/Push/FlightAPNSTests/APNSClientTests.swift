import FlightAPNSTesting
import FlightCore
import FlightTelemetryTesting
import Foundation
import JWTKit
import Synchronization
import Testing

@testable import FlightAPNS

/// A clock the test moves.
private final class TestClock: Sendable {
    private let storage: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_750_000_000)) {
        storage = Mutex(start)
    }

    var now: Date { storage.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        storage.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    var nowProvider: @Sendable () -> Date {
        { self.now }
    }
}

/// A generated signing key and the configuration built around it.
enum Fixture {
    static let privateKey = ES256PrivateKey()

    static func configuration(
        environment: APNSEnvironment = .production, topic: String = "com.example.app"
    ) throws -> APNSConfiguration {
        try APNSConfiguration(
            keyID: "ABC123DEFG", teamID: "TEAM456789", privateKeyPEM: privateKey.pemRepresentation,
            topic: topic, environment: environment)
    }

    static let token = DeviceToken(hex: String(repeating: "ab", count: 32))!
}

@Suite("APNSClient")
struct APNSClientTests {
    private let gateway = RecordingAPNSTransport()
    private let clock = TestClock()

    private func client(_ configuration: APNSConfiguration? = nil) throws -> APNSClient {
        APNSClient(
            configuration: try configuration ?? Fixture.configuration(), transport: gateway,
            now: clock.nowProvider)
    }

    // MARK: The request

    @Test("an alert goes to the production host with the headers Apple reads")
    func requestShape() async throws {
        let receipt = try await client().send(
            .alert(title: "Standup", body: "in 5 minutes", badge: 3), to: Fixture.token)
        #expect(!receipt.apnsID.isEmpty)

        let request = try #require(gateway.sent.last)
        #expect(
            request.url.absoluteString == "https://api.push.apple.com/3/device/\(Fixture.token.hex)"
        )
        #expect(request.header("apns-topic") == "com.example.app")
        #expect(request.header("apns-push-type") == "alert")
        #expect(request.header("apns-priority") == "10")
        #expect(request.header("apns-expiration") == "0")
        #expect(request.header("content-type") == "application/json")
        #expect(request.header("apns-collapse-id") == nil)
        #expect(request.header("authorization")?.hasPrefix("bearer ") == true)

        let payload = try gateway.lastPayload()
        let aps = try #require(payload["aps"] as? [String: Any])
        let alert = try #require(aps["alert"] as? [String: Any])
        #expect(alert["title"] as? String == "Standup")
        #expect(alert["body"] as? String == "in 5 minutes")
        #expect(aps["badge"] as? Int == 3)
        #expect(aps["sound"] as? String == "default")
        #expect(aps["content-available"] == nil)
    }

    @Test("the sandbox environment changes the host and nothing else")
    func sandbox() async throws {
        _ = try await client(Fixture.configuration(environment: .sandbox)).send(
            .background, to: Fixture.token)
        #expect(gateway.sent.last?.url.host == "api.sandbox.push.apple.com")
    }

    @Test("a background push is priority 5 with content-available: 1")
    func background() async throws {
        _ = try await client().send(.background, to: Fixture.token)
        let request = try #require(gateway.sent.last)
        #expect(request.header("apns-push-type") == "background")
        #expect(request.header("apns-priority") == "5")
        let aps = try #require(try gateway.lastPayload()["aps"] as? [String: Any])
        #expect(aps["content-available"] as? Int == 1)
        #expect(aps["alert"] == nil)
    }

    @Test("custom keys sit beside aps, and the wire spellings are Apple's")
    func customPayload() async throws {
        struct Deep: Encodable {
            let conversation: String
            let unread: Int
        }
        var notification = APNSNotification(
            aps: APS(
                alert: APS.Alert(body: "hi"), contentAvailable: false, mutableContent: true,
                category: "MESSAGE", threadID: "t1", interruptionLevel: .timeSensitive,
                relevanceScore: 0.5,
                targetContentID: "c1"),
            custom: Deep(conversation: "abc", unread: 4))
        notification.collapseID = "conv-abc"
        notification.expiration = Date(timeIntervalSince1970: 1_800_000_000)
        notification.id = UUID(uuidString: "0B9E1C6E-9F4C-4D6D-9C8E-1D2F3A4B5C6D")

        _ = try await client().send(notification, to: Fixture.token)
        let request = try #require(gateway.sent.last)
        #expect(request.header("apns-collapse-id") == "conv-abc")
        #expect(request.header("apns-expiration") == "1800000000")
        #expect(request.header("apns-id") == "0b9e1c6e-9f4c-4d6d-9c8e-1d2f3a4b5c6d")

        let payload = try gateway.lastPayload()
        #expect(payload["conversation"] as? String == "abc")
        #expect(payload["unread"] as? Int == 4)
        let aps = try #require(payload["aps"] as? [String: Any])
        #expect(aps["mutable-content"] as? Int == 1)
        #expect(aps["thread-id"] as? String == "t1")
        #expect(aps["interruption-level"] as? String == "time-sensitive")
        #expect(aps["relevance-score"] as? Double == 0.5)
        #expect(aps["target-content-id"] as? String == "c1")
        #expect(aps["category"] as? String == "MESSAGE")
    }

    @Test("push types with a topic suffix get it; an explicit topic is sent as given")
    func topics() throws {
        let client = try client()
        #expect(
            client.topic(for: APNSNotification<Never>(aps: APS(), pushType: .voip))
                == "com.example.app.voip")
        #expect(
            client.topic(for: APNSNotification<Never>(aps: APS(), pushType: .liveactivity))
                == "com.example.app.push-type.liveactivity")
        #expect(
            client.topic(for: APNSNotification<Never>(aps: APS(), pushType: .location))
                == "com.example.app.location-query")
        #expect(
            client.topic(for: APNSNotification<Never>(aps: APS(), pushType: .complication))
                == "com.example.app.complication")
        #expect(
            client.topic(for: APNSNotification<Never>(aps: APS(), pushType: .fileprovider))
                == "com.example.app.pushkit.fileprovider")
        #expect(
            client.topic(for: APNSNotification<Never>(aps: APS(), pushType: .pushtotalk))
                == "com.example.app.voip-ptt")
        #expect(
            client.topic(for: APNSNotification<Never>(aps: APS(), pushType: .widgets))
                == "com.example.app.push-type.widgets")
        #expect(
            client.topic(
                for: APNSNotification<Never>(aps: APS(), pushType: .mdm, topic: "com.apple.mgmt.X"))
                == "com.apple.mgmt.X")
        #expect(
            client.topic(
                for: APNSNotification<Never>(aps: APS(), pushType: .voip, topic: "other.app"))
                == "other.app")
    }

    @Test("an oversized payload is refused before any request")
    func oversized() async throws {
        struct Big: Encodable { let blob: String }
        let notification = APNSNotification(
            aps: APS(alert: APS.Alert(body: "x")),
            custom: Big(blob: String(repeating: "z", count: 5000)))
        await #expect(throws: APNSError.self) {
            try await client().send(notification, to: Fixture.token)
        }
        #expect(gateway.sent.isEmpty)
        do {
            _ = try await client().send(notification, to: Fixture.token)
        } catch let error as APNSError {
            #expect(error.reason == .payloadTooLargeLocally)
            #expect(!error.isRetryable)
        }
    }

    @Test("a custom payload that is not an object is refused before any request")
    func customMustBeObject() async throws {
        let notification = APNSNotification(
            aps: APS(alert: APS.Alert(body: "x")), custom: ["a", "b"])
        do {
            _ = try await client().send(notification, to: Fixture.token)
            Issue.record("expected a refusal")
        } catch let error as APNSError {
            #expect(error.reason == .customPayloadNotAnObject)
        }
        #expect(gateway.sent.isEmpty)
    }

    @Test("an empty custom object adds nothing, and a nested one merges intact")
    func customMerging() async throws {
        struct Empty: Encodable {}
        _ = try await client().send(
            APNSNotification(aps: APS(badge: 1), custom: Empty()), to: Fixture.token)
        #expect(String(decoding: gateway.sent.last!.body, as: UTF8.self) == #"{"aps":{"badge":1}}"#)

        struct Nested: Encodable {
            let data: [String: [Int]]
            let flag: Bool
        }
        _ = try await client().send(
            APNSNotification(
                aps: APS(badge: 1), custom: Nested(data: ["ids": [1, 2]], flag: true)),
            to: Fixture.token)
        let payload = try gateway.lastPayload()
        #expect((payload["data"] as? [String: [Int]])?["ids"] == [1, 2])
        #expect(payload["flag"] as? Bool == true)
        #expect((payload["aps"] as? [String: Any])?["badge"] as? Int == 1)
    }

    // MARK: The answer

    @Test("410 Unregistered says the token is dead, and when")
    func unregistered() async throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        gateway.refuse(status: 410, reason: "Unregistered", timestamp: when, apnsID: "id-410")
        do {
            _ = try await client().send(.alert(body: "hi"), to: Fixture.token)
            Issue.record("expected a refusal")
        } catch let error as APNSError {
            #expect(error.status == 410)
            #expect(error.reason == .unregistered)
            #expect(error.deviceTokenProblem != nil)
            #expect(!error.isRetryable)
            #expect(error.timestamp == when)
            #expect(error.apnsID == "id-410")
        }
    }

    @Test(
        "400 BadDeviceToken is a dead token; 429 and 503 are retryable; an unknown reason is kept verbatim"
    )
    func refusals() async throws {
        gateway.refuse(status: 400, reason: "BadDeviceToken")
        gateway.refuse(status: 429, reason: "TooManyRequests")
        gateway.refuse(status: 503, reason: "ServiceUnavailable")
        gateway.refuse(status: 400, reason: "SomethingNew")
        var errors: [APNSError] = []
        for _ in 0..<4 {
            do { _ = try await client().send(.alert(body: "hi"), to: Fixture.token) } catch let
                error as APNSError
            { errors.append(error) }
        }
        #expect(errors.count == 4)
        #expect(errors[0].reason == .badDeviceToken && errors[0].deviceTokenProblem == .rejected)
        #expect(errors[1].reason == .tooManyRequests && errors[1].isRetryable)
        #expect(errors[2].reason == .serviceUnavailable && errors[2].isRetryable)
        #expect(errors[3].reason == .unknown && errors[3].rawReason == "SomethingNew")
    }

    @Test("a non-JSON error body still yields the status")
    func notJSON() async throws {
        gateway.respond(
            with: APNSRawResponse(status: 502, body: Data("<html>bad gateway</html>".utf8)))
        do {
            _ = try await client().send(.alert(body: "hi"), to: Fixture.token)
        } catch let error as APNSError {
            #expect(error.status == 502)
            #expect(error.reason == .unknown)
            #expect(error.isRetryable)
        }
    }

    @Test("a dropped connection is a retryable transport failure")
    func transportFailure() async throws {
        gateway.misbehave()
        do {
            _ = try await client().send(.alert(body: "hi"), to: Fixture.token)
        } catch let error as APNSError {
            #expect(error.reason == .transportFailure)
            #expect(error.status == 0)
            #expect(error.isRetryable)
        }
    }

    // MARK: The provider token

    /// Decodes and verifies the bearer token of a recorded request against
    /// the fixture's public key.
    private func verifiedClaims(_ request: APNSRequest) async throws -> ProviderTokenClaims {
        let bearer = try #require(request.header("authorization")?.dropFirst("bearer ".count))
        let keys = JWTKeyCollection()
        await keys.add(ecdsa: Fixture.privateKey.publicKey)
        return try await keys.verify(String(bearer), as: ProviderTokenClaims.self)
    }

    @Test(
        "the provider token is ES256 with the key id in the header and team and iat in the claims")
    func providerToken() async throws {
        _ = try await client().send(.alert(body: "hi"), to: Fixture.token)
        let claims = try await verifiedClaims(try #require(gateway.sent.last))
        #expect(claims.iss.value == "TEAM456789")
        #expect(abs(claims.iat.value.timeIntervalSince(clock.now)) < 1)
        let header = try #require(
            gateway.sent.last?.header("authorization")?.split(separator: ".").first)
        let padded = String(header.dropFirst("bearer ".count)).replacingOccurrences(
            of: "-", with: "+"
        ).replacingOccurrences(of: "_", with: "/")
        let json = try #require(
            Data(base64Encoded: padded + String(repeating: "=", count: (4 - padded.count % 4) % 4)))
        let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        #expect(decoded?["alg"] as? String == "ES256")
        #expect(decoded?["kid"] as? String == "ABC123DEFG")
    }

    @Test("the token is reused for fifty minutes and minted afresh after")
    func tokenReuse() async throws {
        let client = try client()
        _ = try await client.send(.alert(body: "1"), to: Fixture.token)
        clock.advance(by: 49 * 60)
        _ = try await client.send(.alert(body: "2"), to: Fixture.token)
        #expect(gateway.sent[0].header("authorization") == gateway.sent[1].header("authorization"))
        clock.advance(by: 2 * 60)
        _ = try await client.send(.alert(body: "3"), to: Fixture.token)
        #expect(gateway.sent[1].header("authorization") != gateway.sent[2].header("authorization"))
        let claims = try await verifiedClaims(gateway.sent[2])
        #expect(abs(claims.iat.value.timeIntervalSince(clock.now)) < 1)
    }

    @Test("ExpiredProviderToken mints a fresh token and retries exactly once")
    func expiredProviderToken() async throws {
        let client = try client()
        _ = try await client.send(.alert(body: "warm"), to: Fixture.token)
        gateway.refuse(status: 403, reason: "ExpiredProviderToken")
        let receipt = try await client.send(.alert(body: "hi"), to: Fixture.token)
        #expect(!receipt.apnsID.isEmpty)
        #expect(gateway.sent.count == 3, "warm-up, the refused attempt, the retry")
        #expect(
            gateway.sent[1].header("authorization") != gateway.sent[2].header("authorization"),
            "retried with a fresh token")

        gateway.refuse(status: 403, reason: "ExpiredProviderToken")
        gateway.refuse(status: 403, reason: "ExpiredProviderToken")
        do {
            _ = try await client.send(.alert(body: "hi"), to: Fixture.token)
            Issue.record("expected the second refusal to surface")
        } catch let error as APNSError {
            #expect(error.reason == .expiredProviderToken)
        }
        #expect(gateway.sent.count == 5, "one retry, not a loop")
    }

    // MARK: Which tokens to forget, and how to retry

    private func refusal(_ reason: APNSError.Reason, status: Int, at timestamp: Date? = nil)
        -> APNSError
    {
        APNSError(status: status, reason: reason, rawReason: reason.rawValue, timestamp: timestamp)
    }

    @Test("a 410 forgets the token only if it was not registered again after it died")
    func forgetRespectsReRegistration() {
        let died = Date(timeIntervalSince1970: 1_700_000_000)
        let gone = refusal(.unregistered, status: 410, at: died)
        #expect(gone.deviceTokenProblem == .inactive(since: died))
        #expect(gone.shouldForgetDeviceToken(registeredAt: died.addingTimeInterval(-60)))
        #expect(
            !gone.shouldForgetDeviceToken(registeredAt: died.addingTimeInterval(60)),
            "re-registered after the token died: a late 410 must not delete it")
        #expect(gone.shouldForgetDeviceToken(registeredAt: nil))
        #expect(refusal(.expiredToken, status: 410).shouldForgetDeviceToken(registeredAt: .now))
    }

    @Test(
        "BadDeviceToken and DeviceTokenNotForTopic never delete: that is what a misconfigured environment looks like"
    )
    func misconfigurationNeverDeletes() {
        let wrongEnvironment = refusal(.badDeviceToken, status: 400)
        #expect(wrongEnvironment.deviceTokenProblem == .rejected)
        #expect(!wrongEnvironment.shouldForgetDeviceToken(registeredAt: nil))
        let wrongTopic = refusal(.deviceTokenNotForTopic, status: 400)
        #expect(wrongTopic.deviceTokenProblem == .wrongTopic)
        #expect(!wrongTopic.shouldForgetDeviceToken(registeredAt: nil))
        #expect(refusal(.badTopic, status: 400).deviceTokenProblem == nil)
    }

    @Test("retry advice separates throttling, gateway failure and a lost connection")
    func retryAdvice() {
        #expect(refusal(.tooManyRequests, status: 429).retryAdvice == .throttled)
        #expect(refusal(.tooManyProviderTokenUpdates, status: 429).retryAdvice == .throttled)
        #expect(refusal(.serviceUnavailable, status: 503).retryAdvice == .backOff)
        #expect(refusal(.unknown, status: 502).retryAdvice == .backOff)
        #expect(refusal(.transportFailure, status: 0).retryAdvice == .reconnect)
        #expect(refusal(.idleTimeout, status: 400).retryAdvice == .reconnect)
        #expect(refusal(.badDeviceToken, status: 400).retryAdvice == .never)
        #expect(refusal(.unregistered, status: 410).retryAdvice == .never)
        #expect(refusal(.serviceUnavailable, status: 503).isRetryable)
        #expect(!refusal(.payloadTooLarge, status: 413).isRetryable)
    }

    @Test("each send reports its outcome, and each provider token minted is reported")
    func sendEvents() async throws {
        let client = APNSClient(
            configuration: try Fixture.configuration(), transport: gateway, now: clock.nowProvider)
        let events = try await TelemetryTest.capture(prefix: "flight.apns") {
            _ = try await client.send(.alert(body: "hi"), to: Fixture.token)
            gateway.refuse(status: 410, reason: "Unregistered", timestamp: .now)
            _ = try? await client.send(.alert(body: "hi"), to: Fixture.token)
        }
        #expect(events.map(\.name) == [
            "flight.apns.provider_token_minted", "flight.apns.send", "flight.apns.send",
        ], "one token, reused rather than re-minted")
        #expect(events.dropFirst().map { $0[metadata: "outcome"] } == ["delivered", "Unregistered"])
    }

    @Test("the default metrics report under the names 0.33 used")
    func metricNames() {
        #expect(APNSMetrics.definitions.map { $0.descriptor.name.replacingOccurrences(of: ".", with: "_") } == [
            APNSMetrics.sends, APNSMetrics.sendDuration, APNSMetrics.providerTokensMinted,
        ])
    }
}
