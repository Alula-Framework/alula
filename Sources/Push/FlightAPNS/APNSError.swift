import Foundation

/// Why a push was not accepted, as the gateway said it — plus the one bit an
/// application has to act on, ``deviceTokenIsInvalid``, and the one it may
/// act on, ``isRetryable``.
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
    /// `410 Unregistered` only: when the device token stopped being valid.
    /// A token registered again after this moment is a different token.
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

    /// The token will never deliver again: stop storing it. Sending to a
    /// token Apple has told you is dead is what gets a provider throttled.
    public var deviceTokenIsInvalid: Bool {
        switch reason {
        case .badDeviceToken, .unregistered, .deviceTokenNotForTopic, .expiredToken: return true
        default: return false
        }
    }

    /// The same request may succeed later: the gateway is busy, restarting,
    /// or the network was. Not a promise — the caller owns the backoff.
    public var isRetryable: Bool {
        switch reason {
        case .tooManyRequests, .internalServerError, .serviceUnavailable, .shutdown, .idleTimeout,
            .transportFailure:
            return true
        default:
            return status >= 500
        }
    }

    public var description: String {
        var parts = ["APNs refused the push"]
        if status > 0 { parts.append("HTTP \(status)") }
        parts.append(rawReason)
        if let apnsID { parts.append("apns-id \(apnsID)") }
        return parts.joined(separator: ", ")
    }
}
