import Foundation

/// Why a push was not accepted, as the gateway said it — plus what an
/// application has to act on, ``deviceTokenProblem`` and
/// ``shouldForgetDeviceToken(registeredAt:)``, and what it may act on,
/// ``retryAdvice``.
public struct APNSError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Apple's `reason` strings, verbatim as raw values, with two of this
    /// package's own at the end for failures the gateway never saw.
    public enum Reason: String, Sendable, Equatable {
        case badCollapseID = "BadCollapseId"
        case badDeviceToken = "BadDeviceToken"
        case badExpirationDate = "BadExpirationDate"
        case badMessageID = "BadMessageId"
        case badPriority = "BadPriority"
        case badTopic = "BadTopic"
        case deviceTokenNotForTopic = "DeviceTokenNotForTopic"
        case duplicateHeaders = "DuplicateHeaders"
        case idleTimeout = "IdleTimeout"
        case invalidPushType = "InvalidPushType"
        case missingDeviceToken = "MissingDeviceToken"
        case missingTopic = "MissingTopic"
        case payloadEmpty = "PayloadEmpty"
        case topicDisallowed = "TopicDisallowed"
        case badCertificate = "BadCertificate"
        case badCertificateEnvironment = "BadCertificateEnvironment"
        case expiredProviderToken = "ExpiredProviderToken"
        case forbidden = "Forbidden"
        case invalidProviderToken = "InvalidProviderToken"
        case missingProviderToken = "MissingProviderToken"
        case badPath = "BadPath"
        case methodNotAllowed = "MethodNotAllowed"
        case expiredToken = "ExpiredToken"
        case unregistered = "Unregistered"
        case payloadTooLarge = "PayloadTooLarge"
        case tooManyProviderTokenUpdates = "TooManyProviderTokenUpdates"
        case tooManyRequests = "TooManyRequests"
        case internalServerError = "InternalServerError"
        case serviceUnavailable = "ServiceUnavailable"
        case shutdown = "Shutdown"
        /// A reason string this version does not know. `rawReason` has it.
        case unknown = "flight:unknown"
        /// The request never got an answer: connection, TLS, timeout.
        case transportFailure = "flight:transport"
        /// Refused here, before any request: the payload exceeds the type's
        /// ceiling.
        case payloadTooLargeLocally = "flight:payload-too-large"
        /// Refused here, before any request: `Custom` did not encode as a
        /// JSON object, so it cannot sit beside `aps`.
        case customPayloadNotAnObject = "flight:custom-not-object"
    }

    /// The HTTP status, or 0 when the gateway never answered.
    public let status: Int
    public let reason: Reason
    /// The gateway's `reason` verbatim, or the local description.
    public let rawReason: String
    /// The `apns-id` of the refused request, when the gateway assigned one.
    public let apnsID: String?
    /// On a `410` (`Unregistered`, `ExpiredToken`): when the device token
    /// stopped being valid for the topic. A token registered again after
    /// this moment is alive — see ``shouldForgetDeviceToken(registeredAt:)``.
    public let timestamp: Date?

    public init(
        status: Int, reason: Reason, rawReason: String, apnsID: String? = nil,
        timestamp: Date? = nil
    ) {
        self.status = status
        self.reason = reason
        self.rawReason = rawReason
        self.apnsID = apnsID
        self.timestamp = timestamp
    }

    /// What the gateway said about the device token itself — which is not
    /// always "delete it".
    public enum DeviceTokenProblem: Sendable, Equatable {
        /// `410 Unregistered` / `410 ExpiredToken`: the token stopped being
        /// valid for the topic at `since`. A token the device registered
        /// again *after* that moment is alive; see
        /// ``shouldForgetDeviceToken(registeredAt:)``.
        case inactive(since: Date?)
        /// `400 BadDeviceToken`: malformed — **or** a perfectly good token
        /// sent to the other environment (a sandbox token to production).
        /// When every token starts failing this way at once, it is the
        /// environment, not the tokens.
        case rejected
        /// `400 DeviceTokenNotForTopic`: the token belongs to a different app
        /// than the configured topic — usually the topic is what is wrong.
        case wrongTopic
    }

    /// What is wrong with the device token, when the refusal is about it.
    public var deviceTokenProblem: DeviceTokenProblem? {
        switch reason {
        case .unregistered, .expiredToken: return .inactive(since: timestamp)
        case .badDeviceToken: return .rejected
        case .deviceTokenNotForTopic: return .wrongTopic
        default: return nil
        }
    }

    /// Whether to delete the stored token that produced this answer.
    ///
    /// Only for an *inactive* token, and only if it was not registered again
    /// after Apple stopped accepting it. A device that reinstalls or
    /// re-registers gets a token that is valid again, and a slow 410 from a
    /// push sent before that must not delete it:
    ///
    ///     T1  APNs marks the token inactive      (timestamp = T1)
    ///     T2  the device registers again         (registeredAt = T2)
    ///     T3  the 410 from a T0 push arrives     → T2 > T1: keep it
    ///
    /// `rejected` and `wrongTopic` answer false: both are what *every* token
    /// returns when the environment or topic is misconfigured, and deleting
    /// on them turns one configuration mistake into losing every device an
    /// application knows about. Forget a token on those only when it keeps
    /// failing while other tokens to the same topic succeed.
    ///
    /// - Parameter registeredAt: When the stored token was last registered
    ///   or confirmed by the device. Nil deletes on any inactive answer.
    public func shouldForgetDeviceToken(registeredAt: Date?) -> Bool {
        guard case .inactive(let since) = deviceTokenProblem else { return false }
        guard let since, let registeredAt else { return true }
        return registeredAt <= since
    }

    /// Replaced by ``deviceTokenProblem`` and
    /// ``shouldForgetDeviceToken(registeredAt:)``. This returned true for
    /// `BadDeviceToken` and `DeviceTokenNotForTopic` too, which are also what
    /// every token returns under a misconfigured environment or topic — so
    /// deleting on it could delete every stored token at once.
    @available(
        *, deprecated,
        message:
            "use shouldForgetDeviceToken(registeredAt:) or deviceTokenProblem; this also flagged tokens that fail only because the environment or topic is misconfigured"
    )
    public var deviceTokenIsInvalid: Bool { deviceTokenProblem != nil }

    /// How trying again could help — the policy stays the caller's.
    public enum RetryAdvice: Sendable, Equatable {
        /// It will fail the same way. Fix the request, the token or the
        /// configuration.
        case never
        /// The gateway is failing (5xx, `Shutdown`, `ServiceUnavailable`):
        /// retry with exponential backoff and jitter.
        case backOff
        /// Sent too fast (`429 TooManyRequests`,
        /// `TooManyProviderTokenUpdates`): slow down — the whole stream to
        /// this token or provider, not only this push.
        case throttled
        /// No usable answer — the connection failed or went idle: retry
        /// soon, on a fresh connection.
        case reconnect
    }

    public var retryAdvice: RetryAdvice {
        switch reason {
        case .tooManyRequests, .tooManyProviderTokenUpdates: return .throttled
        case .idleTimeout, .transportFailure: return .reconnect
        case .internalServerError, .serviceUnavailable, .shutdown: return .backOff
        default: return status >= 500 ? .backOff : .never
        }
    }

    /// The same request may succeed later. ``retryAdvice`` says how.
    public var isRetryable: Bool { retryAdvice != .never }

    public var description: String {
        var parts = ["APNs refused the push"]
        if status > 0 { parts.append("HTTP \(status)") }
        parts.append(rawReason)
        if let apnsID { parts.append("apns-id \(apnsID)") }
        return parts.joined(separator: ", ")
    }
}
