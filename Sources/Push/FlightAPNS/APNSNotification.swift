import Foundation

/// A device's registration token, as the app on the device received it from
/// `didRegisterForRemoteNotificationsWithDeviceToken`, hex-encoded.
///
/// Validated to be hex and non-empty, and nothing else: Apple has changed
/// the length before and says not to assume one.
public struct DeviceToken: Sendable, Hashable, CustomStringConvertible {
    public let hex: String

    /// `nil` unless `hex` is a non-empty string of hexadecimal digits.
    public init?(hex: String) {
        guard !hex.isEmpty, hex.allSatisfy(\.isHexDigit) else { return nil }
        self.hex = hex.lowercased()
    }

    /// The token, from its raw bytes.
    public init(bytes: some Sequence<UInt8>) {
        self.hex = bytes.map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { hex }
}

/// What kind of push this is — the `apns-push-type` header, which Apple
/// requires and which decides how the device treats the delivery.
public enum PushType: String, Sendable, Equatable, CaseIterable {
    case alert
    case background
    case location
    case voip
    case complication
    case fileprovider
    case mdm
    case liveactivity
    case pushtotalk
    case widgets

    /// What Apple appends to the bundle id for this type's topic. `nil`
    /// means the bundle id itself (or, for `mdm`, the topic from the push
    /// certificate, which the caller supplies).
    var topicSuffix: String? {
        switch self {
        case .alert, .background, .mdm: return nil
        case .location: return ".location-query"
        case .voip: return ".voip"
        case .complication: return ".complication"
        case .fileprovider: return ".pushkit.fileprovider"
        case .liveactivity: return ".push-type.liveactivity"
        case .pushtotalk: return ".voip-ptt"
        case .widgets: return ".push-type.widgets"
        }
    }

    /// Apple's payload ceiling: 5 KB for VoIP, 4 KB for everything else.
    var maximumPayloadBytes: Int {
        self == .voip ? 5120 : 4096
    }
}

/// The `apns-priority` header.
public enum PushPriority: Int, Sendable, Equatable {
    /// Deliver now. The only choice for `alert`; wakes the device.
    case immediate = 10
    /// Deliver when power allows. Required for `background`.
    case conserve = 5
    /// Deliver on the device's own schedule. Background only.
    case lowest = 1
}

/// The `aps` dictionary: what the system does with the notification.
///
/// Every field is optional and only the ones set are encoded, under the
/// exact keys Apple reads — `content-available`, `mutable-content` and the
/// rest are hyphenated on the wire, and that is spelled here once.
public struct APS: Sendable, Equatable, Encodable {
    public struct Alert: Sendable, Equatable, Encodable {
        public var title: String?
        public var subtitle: String?
        public var body: String?
        public var launchImage: String?

        public init(
            title: String? = nil, subtitle: String? = nil, body: String? = nil,
            launchImage: String? = nil
        ) {
            self.title = title
            self.subtitle = subtitle
            self.body = body
            self.launchImage = launchImage
        }

        private enum CodingKeys: String, CodingKey {
            case title, subtitle, body
            case launchImage = "launch-image"
        }
    }

    public enum InterruptionLevel: String, Sendable, Equatable, Encodable {
        case passive
        case active
        case timeSensitive = "time-sensitive"
        case critical
    }

    public var alert: Alert?
    public var badge: Int?
    /// A sound file in the app bundle, or `"default"`.
    public var sound: String?
    /// `content-available: 1` — wake the app in the background.
    public var contentAvailable: Bool
    /// `mutable-content: 1` — run the notification service extension.
    public var mutableContent: Bool
    public var category: String?
    public var threadID: String?
    public var interruptionLevel: InterruptionLevel?
    /// 0…1, how the system sorts notifications in a summary.
    public var relevanceScore: Double?
    public var targetContentID: String?

    public init(
        alert: Alert? = nil,
        badge: Int? = nil,
        sound: String? = nil,
        contentAvailable: Bool = false,
        mutableContent: Bool = false,
        category: String? = nil,
        threadID: String? = nil,
        interruptionLevel: InterruptionLevel? = nil,
        relevanceScore: Double? = nil,
        targetContentID: String? = nil
    ) {
        self.alert = alert
        self.badge = badge
        self.sound = sound
        self.contentAvailable = contentAvailable
        self.mutableContent = mutableContent
        self.category = category
        self.threadID = threadID
        self.interruptionLevel = interruptionLevel
        self.relevanceScore = relevanceScore
        self.targetContentID = targetContentID
    }

    private enum CodingKeys: String, CodingKey {
        case alert, badge, sound, category
        case contentAvailable = "content-available"
        case mutableContent = "mutable-content"
        case threadID = "thread-id"
        case interruptionLevel = "interruption-level"
        case relevanceScore = "relevance-score"
        case targetContentID = "target-content-id"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(alert, forKey: .alert)
        try container.encodeIfPresent(badge, forKey: .badge)
        try container.encodeIfPresent(sound, forKey: .sound)
        if contentAvailable { try container.encode(1, forKey: .contentAvailable) }
        if mutableContent { try container.encode(1, forKey: .mutableContent) }
        try container.encodeIfPresent(category, forKey: .category)
        try container.encodeIfPresent(threadID, forKey: .threadID)
        try container.encodeIfPresent(interruptionLevel, forKey: .interruptionLevel)
        try container.encodeIfPresent(relevanceScore, forKey: .relevanceScore)
        try container.encodeIfPresent(targetContentID, forKey: .targetContentID)
    }
}

/// One notification: the `aps` dictionary, the application's own keys
/// beside it, and the headers that tell the gateway how to deliver it.
///
/// `Custom` is encoded as top-level siblings of `aps` — the shape Apple
/// reads custom data in — so it must encode as an object with keys. Use
/// `Never` when there is none.
public struct APNSNotification<Custom: Encodable & Sendable>: Sendable {
    public var aps: APS
    public var custom: Custom?
    public var pushType: PushType
    public var priority: PushPriority
    /// When the gateway may stop trying. `nil` is "try once, now".
    public var expiration: Date?
    /// Notifications sharing an id collapse to the newest on the device.
    public var collapseID: String?
    /// Overrides the configured topic — for a second app, or an `mdm` push.
    /// Otherwise the configured bundle id, with the push type's suffix.
    public var topic: String?
    /// A UUID of your own for the `apns-id` header; the gateway assigns one
    /// when this is `nil`, and the receipt carries it either way.
    public var id: UUID?

    public init(
        aps: APS,
        custom: Custom? = nil,
        pushType: PushType = .alert,
        priority: PushPriority = .immediate,
        expiration: Date? = nil,
        collapseID: String? = nil,
        topic: String? = nil,
        id: UUID? = nil
    ) {
        self.aps = aps
        self.custom = custom
        self.pushType = pushType
        self.priority = priority
        self.expiration = expiration
        self.collapseID = collapseID
        self.topic = topic
        self.id = id
    }
}

extension APNSNotification where Custom == Never {
    /// A user-visible alert with no custom data.
    public static func alert(
        title: String? = nil, subtitle: String? = nil, body: String, sound: String? = "default",
        badge: Int? = nil
    ) -> APNSNotification<Never> {
        APNSNotification(
            aps: APS(
                alert: APS.Alert(title: title, subtitle: subtitle, body: body), badge: badge,
                sound: sound))
    }

    /// A silent background push with no custom data.
    public static var background: APNSNotification<Never> {
        APNSNotification(
            aps: APS(contentAvailable: true), pushType: .background, priority: .conserve)
    }
}

/// The wire form: `aps`, then the custom keys beside it.
///
/// Encoded in two passes and spliced, rather than by asking one encoder for
/// two containers. `JSONEncoder` *traps* — not throws — when a second
/// container of a different kind is requested on the same encoder, so a
/// `Custom` that encodes as an array would take the process down. Encoding
/// it on its own first makes "is it an object" a question with a checkable
/// answer: the bytes start with `{`, or they do not.
enum APNSPayload {
    private struct Envelope: Encodable {
        let aps: APS
    }

    /// The complete payload, or ``APNSError/Reason/customPayloadNotAnObject``.
    static func encode<Custom: Encodable>(aps: APS, custom: Custom?, with encoder: JSONEncoder)
        throws -> Data
    {
        let base = try encoder.encode(Envelope(aps: aps))
        guard let custom else { return base }
        let extra = try encoder.encode(custom)
        guard extra.first == UInt8(ascii: "{"), extra.last == UInt8(ascii: "}") else {
            throw APNSError(
                status: 0, reason: .customPayloadNotAnObject,
                rawReason:
                    "custom payload must encode as a JSON object; it encoded as \(String(decoding: extra.prefix(16), as: UTF8.self))…"
            )
        }
        // `{}` adds nothing. Otherwise: base minus its closing brace, a
        // comma, custom minus its opening brace.
        guard extra.count > 2 else { return base }
        var merged = base.dropLast()
        merged.append(UInt8(ascii: ","))
        merged.append(contentsOf: extra.dropFirst())
        return Data(merged)
    }
}
