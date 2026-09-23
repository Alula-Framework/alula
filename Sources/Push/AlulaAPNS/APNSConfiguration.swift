import AlulaCore
import Foundation
import JWTKit

/// The `apns.*` configuration vocabulary (env-var form `ALULA_APNS_*`).
public enum APNSConfigKey {
    public static let root = "apns"
    /// `apns.key-id` — the ten-character id of the signing key, from the
    /// Apple developer portal.
    public static let keyID = "apns.key-id"
    /// `apns.team-id` — the ten-character team id.
    public static let teamID = "apns.team-id"
    /// `apns.private-key` — the `.p8` file's contents, PEM. The form a
    /// secret reaches a container in: `ALULA_APNS_PRIVATE_KEY`.
    public static let privateKey = "apns.private-key"
    /// `apns.private-key-path` — a path to the `.p8` file, read once at
    /// composition. One of the two; both is a configuration error.
    public static let privateKeyPath = "apns.private-key-path"
    /// `apns.topic` — the app's bundle identifier. A notification's own
    /// `topic` overrides it; push types with a suffix get it appended.
    public static let topic = "apns.topic"
    /// `apns.environment` — `production` or `sandbox`.
    public static let environment = "apns.environment"
    /// `apns.request-timeout` — one request, connection included.
    public static let requestTimeout = "apns.request-timeout"
}

/// Which of Apple's two gateways to talk to.
public enum APNSEnvironment: String, Sendable, Equatable, ConfigDecodable {
    case production
    case sandbox

    public init?(configValue: String) {
        self.init(rawValue: configValue.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// The gateway host. Port 443; Apple also serves 2197 for networks that
    /// block it, which nothing here needs yet.
    public var host: String {
        switch self {
        case .production: return "api.push.apple.com"
        case .sandbox: return "api.sandbox.push.apple.com"
        }
    }
}

/// Loaded, validated settings — read once at composition, so a missing key,
/// an unparseable `.p8`, or an unknown environment fails startup rather than
/// the first push.
///
/// The private key is parsed here, into JWTKit's `ES256PrivateKey`, and the
/// PEM is not kept. `description` names everything but the key.
public struct APNSConfiguration: Sendable, CustomStringConvertible {
    public let keyID: String
    public let teamID: String
    public let privateKey: ES256PrivateKey
    public let topic: String
    public let environment: APNSEnvironment
    public let requestTimeout: Duration

    public enum Defaults {
        public static let environment = APNSEnvironment.production
        public static let requestTimeout: Duration = .seconds(10)
    }

    /// - Parameters:
    ///   - keyID: The ten-character id of the signing key.
    ///   - teamID: The ten-character team id; the provider token's `iss`.
    ///   - privateKeyPEM: The `.p8` contents. Parsed here; a key that is not
    ///     a P-256 private key throws.
    ///   - topic: The bundle identifier.
    ///   - environment: Production or sandbox.
    ///   - requestTimeout: One request, connection included.
    public init(
        keyID: String,
        teamID: String,
        privateKeyPEM: String,
        topic: String,
        environment: APNSEnvironment = Defaults.environment,
        requestTimeout: Duration = Defaults.requestTimeout
    ) throws {
        guard !keyID.isEmpty else {
            throw APNSConfigurationError.emptyValue(key: APNSConfigKey.keyID)
        }
        guard !teamID.isEmpty else {
            throw APNSConfigurationError.emptyValue(key: APNSConfigKey.teamID)
        }
        guard !topic.isEmpty else {
            throw APNSConfigurationError.emptyValue(key: APNSConfigKey.topic)
        }
        guard requestTimeout > .zero else {
            throw APNSConfigurationError.nonPositiveTimeout(requestTimeout)
        }
        do {
            self.privateKey = try ES256PrivateKey(pem: privateKeyPEM)
        } catch {
            throw APNSConfigurationError.invalidPrivateKey(reason: "\(error)")
        }
        self.keyID = keyID
        self.teamID = teamID
        self.topic = topic
        self.environment = environment
        self.requestTimeout = requestTimeout
    }

    /// Reads `apns.*`. Exactly one of `private-key` and `private-key-path`
    /// must be set; a path is read here, once.
    public init(configuration: Configuration) throws {
        let inline: String? = try configuration.getIfPresent(APNSConfigKey.privateKey)
        let path: String? = try configuration.getIfPresent(APNSConfigKey.privateKeyPath)
        let pem: String
        switch (inline, path) {
        case (let inline?, nil):
            pem = inline
        case (nil, let path?):
            do {
                pem = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                throw APNSConfigurationError.unreadablePrivateKeyFile(
                    path: path, reason: "\(error)")
            }
        case (nil, nil):
            throw APNSConfigurationError.missingPrivateKey
        case (.some, .some):
            throw APNSConfigurationError.bothPrivateKeySources
        }
        try self.init(
            keyID: try configuration.get(APNSConfigKey.keyID),
            teamID: try configuration.get(APNSConfigKey.teamID),
            privateKeyPEM: pem,
            topic: try configuration.get(APNSConfigKey.topic),
            environment: try configuration.getIfPresent(APNSConfigKey.environment)
                ?? Defaults.environment,
            requestTimeout: try configuration.getIfPresent(APNSConfigKey.requestTimeout)
                ?? Defaults.requestTimeout)
    }

    /// Everything but the key.
    public var description: String {
        "APNSConfiguration(keyID: \(keyID), teamID: \(teamID), topic: \(topic), "
            + "environment: \(environment.rawValue), requestTimeout: \(requestTimeout), privateKey: <REDACTED>)"
    }
}

/// An `apns.*` value that cannot be used. Thrown at composition.
public enum APNSConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingPrivateKey
    case bothPrivateKeySources
    case unreadablePrivateKeyFile(path: String, reason: String)
    case invalidPrivateKey(reason: String)
    case emptyValue(key: String)
    case nonPositiveTimeout(Duration)

    public var description: String {
        switch self {
        case .missingPrivateKey:
            return """
                Neither \(APNSConfigKey.privateKey) nor \(APNSConfigKey.privateKeyPath) is set. One of \
                them must carry the .p8 signing key — the contents, or a path to the file.
                """
        case .bothPrivateKeySources:
            return """
                Both \(APNSConfigKey.privateKey) and \(APNSConfigKey.privateKeyPath) are set. Set one: \
                two sources of one key is a configuration with no single answer.
                """
        case .unreadablePrivateKeyFile(let path, let reason):
            return "\(APNSConfigKey.privateKeyPath) '\(path)' could not be read: \(reason)"
        case .invalidPrivateKey(let reason):
            return """
                The APNs private key is not a PEM-encoded P-256 private key (the contents of the .p8 \
                file Apple issues): \(reason)
                """
        case .emptyValue(let key):
            return "\(key) is empty."
        case .nonPositiveTimeout(let value):
            return "\(APNSConfigKey.requestTimeout) must be positive; it is \(value)."
        }
    }
}
