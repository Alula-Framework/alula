import Foundation
import Logging
import TelemetryCore

/// What the gateway answered for an accepted push.
public struct APNSReceipt: Sendable, Equatable {
    /// The `apns-id`: yours if you set one, the gateway's otherwise. What to
    /// quote to Apple, and what to log.
    public let apnsID: String

    public init(apnsID: String) {
        self.apnsID = apnsID
    }
}

/// Sends notifications: one request per call, a provider token minted and
/// reused underneath, and the gateway's answer read into ``APNSReceipt`` or
/// ``APNSError``.
///
/// No queue, no batching, no retry policy beyond the one the protocol itself
/// asks for (a fresh provider token after `ExpiredProviderToken`, once).
/// Fan-out and backoff are the application's — a task group over the tokens
/// it holds, a scheduled job that drains a table — because the right policy
/// depends on what the pushes are, and a client that guesses is a client
/// that surprises. What this client promises is that one call is one
/// delivery attempt, with a typed answer.
public final class APNSClient: Sendable {
    public let configuration: APNSConfiguration
    private let transport: any APNSTransport
    private let tokens: ProviderTokenSource
    private let logger: Logger
    private let encoder: JSONEncoder

    /// - Parameters:
    ///   - configuration: Key, team, topic, environment.
    ///   - transport: The network. `AsyncHTTPAPNSTransport` by default;
    ///     `FlightAPNSTesting.RecordingAPNSTransport` in tests.
    ///   - now: The clock, injectable so provider-token refresh is testable.
    ///   - logger: Where the one debug line this client writes goes.
    ///
    /// Sends and provider tokens are reported as ``APNSEvents``.
    public init(
        configuration: APNSConfiguration,
        transport: any APNSTransport = AsyncHTTPAPNSTransport(),
        now: @escaping @Sendable () -> Date = Date.init,
        logger: Logger? = nil
    ) {
        self.configuration = configuration
        self.transport = transport
        self.tokens = ProviderTokenSource(
            keyID: configuration.keyID, teamID: configuration.teamID,
            privateKey: configuration.privateKey, now: now)
        self.logger = logger ?? Logger(label: "flight.apns")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        self.encoder = encoder
    }

    /// One delivery attempt.
    ///
    /// - Throws: ``APNSError`` for anything the gateway refused or the
    ///   network lost, and for a payload refused here — too large, or a
    ///   `Custom` that is not an object.
    public func send<Custom>(
        _ notification: APNSNotification<Custom>, to token: DeviceToken
    ) async throws -> APNSReceipt {
        let start = Telemetry.isEnabled(APNSEvents.Send.self) ? ContinuousClock.now : nil
        do {
            let receipt = try await sendUncounted(notification, to: token)
            APNSEvents.sent("delivered", since: start)
            return receipt
        } catch let error as APNSError {
            APNSEvents.sent(error.reason.rawValue, since: start)
            throw error
        }
    }

    private func sendUncounted<Custom>(
        _ notification: APNSNotification<Custom>, to token: DeviceToken
    ) async throws -> APNSReceipt {
        let body = try APNSPayload.encode(
            aps: notification.aps, custom: notification.custom, with: encoder)
        guard body.count <= notification.pushType.maximumPayloadBytes else {
            throw APNSError(
                status: 0, reason: .payloadTooLargeLocally,
                rawReason:
                    "payload is \(body.count) bytes; \(notification.pushType.rawValue) pushes may carry \(notification.pushType.maximumPayloadBytes)"
            )
        }
        let request = try await request(for: notification, to: token, body: body)
        let response: APNSRawResponse
        do {
            response = try await transport.post(request)
        } catch {
            throw APNSError(status: 0, reason: .transportFailure, rawReason: "\(error)")
        }
        switch Self.interpret(response) {
        case .accepted(let receipt):
            return receipt
        case .refused(let error) where error.reason == .expiredProviderToken:
            // The one retry the protocol asks for: mint a fresh token and
            // try once more. A second refusal is reported.
            logger.debug("provider token expired; minting a fresh one and retrying once")
            tokens.invalidate()
            let retried: APNSRawResponse
            do {
                retried = try await transport.post(
                    try await self.request(for: notification, to: token, body: body))
            } catch {
                throw APNSError(status: 0, reason: .transportFailure, rawReason: "\(error)")
            }
            switch Self.interpret(retried) {
            case .accepted(let receipt): return receipt
            case .refused(let error): throw error
            }
        case .refused(let error):
            throw error
        }
    }

    // MARK: - Building the request

    private func request<Custom>(
        for notification: APNSNotification<Custom>, to token: DeviceToken, body: Data
    ) async throws -> APNSRequest {
        guard
            let url = URL(string: "https://\(configuration.environment.host)/3/device/\(token.hex)")
        else {
            throw APNSError(
                status: 0, reason: .badDeviceToken, rawReason: "device token does not form a URL")
        }
        var headers: [(name: String, value: String)] = [
            ("authorization", "bearer \(try await tokens.token())"),
            ("apns-topic", topic(for: notification)),
            ("apns-push-type", notification.pushType.rawValue),
            ("apns-priority", String(notification.priority.rawValue)),
            (
                "apns-expiration",
                String(Int((notification.expiration?.timeIntervalSince1970 ?? 0).rounded()))
            ),
            ("content-type", "application/json"),
        ]
        if let collapseID = notification.collapseID {
            headers.append(("apns-collapse-id", collapseID))
        }
        if let id = notification.id {
            headers.append(("apns-id", id.uuidString.lowercased()))
        }
        return APNSRequest(
            url: url, headers: headers, body: body, timeout: configuration.requestTimeout)
    }

    /// The configured bundle id with the push type's suffix, unless the
    /// notification names its own topic — in which case it is sent as given.
    func topic<Custom>(for notification: APNSNotification<Custom>) -> String {
        if let topic = notification.topic { return topic }
        return configuration.topic + (notification.pushType.topicSuffix ?? "")
    }

    // MARK: - Reading the answer

    enum Outcome: Equatable {
        case accepted(APNSReceipt)
        case refused(APNSError)
    }

    private struct ErrorBody: Decodable {
        let reason: String
        let timestamp: Double?
    }

    /// A 200 is a receipt. Anything else is an error whose `reason` comes
    /// from the JSON body when there is one, and from the status when the
    /// body is missing or not JSON — the gateway is not the only thing that
    /// can answer on that connection.
    static func interpret(_ response: APNSRawResponse) -> Outcome {
        let apnsID = response.headers["apns-id"]
        if response.status == 200 {
            return .accepted(APNSReceipt(apnsID: apnsID ?? ""))
        }
        let parsed = try? JSONDecoder().decode(ErrorBody.self, from: response.body)
        let rawReason = parsed?.reason ?? "HTTP \(response.status) with no reason"
        let reason = parsed.flatMap { APNSError.Reason(rawValue: $0.reason) } ?? .unknown
        let timestamp = parsed?.timestamp.map { Date(timeIntervalSince1970: $0 / 1000) }
        return .refused(
            APNSError(
                status: response.status, reason: reason, rawReason: rawReason, apnsID: apnsID,
                timestamp: response.status == 410 ? timestamp : nil))
    }
}
