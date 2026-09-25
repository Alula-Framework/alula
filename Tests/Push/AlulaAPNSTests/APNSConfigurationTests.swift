import AlulaCore
import Foundation
import JWTKit
import Testing

@testable import AlulaAPNS

@Suite("APNSConfiguration")
struct APNSConfigurationTests {
    private let pem = ES256PrivateKey().pemRepresentation

    private func configuration(_ values: [String: String]) throws -> APNSConfiguration {
        try APNSConfiguration(configuration: Configuration(values: values))
    }

    private var minimal: [String: String] {
        [
            "apns.key-id": "ABC123DEFG", "apns.team-id": "TEAM456789", "apns.private-key": pem,
            "apns.topic": "com.example.app",
        ]
    }

    @Test("the minimum: key id, team id, the key, and a topic — production by default")
    func minimalConfiguration() throws {
        let settings = try configuration(minimal)
        #expect(settings.keyID == "ABC123DEFG")
        #expect(settings.teamID == "TEAM456789")
        #expect(settings.topic == "com.example.app")
        #expect(settings.environment == .production)
        #expect(settings.requestTimeout == .seconds(10))
    }

    @Test("the key may come from a file instead")
    func keyFromFile() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apns-\(UUID().uuidString).p8"
        ).path
        try pem.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        var values = minimal
        values.removeValue(forKey: "apns.private-key")
        values["apns.private-key-path"] = path
        _ = try configuration(values)
    }

    @Test("environment and timeout are read, kebab-case")
    func optionalKeys() throws {
        var values = minimal
        values["apns.environment"] = "Sandbox"
        values["apns.request-timeout"] = "3s"
        let settings = try configuration(values)
        #expect(settings.environment == .sandbox)
        #expect(settings.requestTimeout == .seconds(3))
    }

    @Test("each required key missing fails, naming the key")
    func missingKeys() {
        for key in ["apns.key-id", "apns.team-id", "apns.topic"] {
            var values = minimal
            values.removeValue(forKey: key)
            #expect(throws: (any Error).self, "\(key)") { try configuration(values) }
            do { _ = try configuration(values) } catch {
                #expect("\(error)".contains(key), "\(error)")
            }
        }
    }

    @Test("no key source, both key sources, an unreadable file, and a bad PEM are refused")
    func keyProblems() {
        var none = minimal
        none.removeValue(forKey: "apns.private-key")
        #expect(throws: APNSConfigurationError.missingPrivateKey) { try configuration(none) }

        var both = minimal
        both["apns.private-key-path"] = "/nonexistent.p8"
        #expect(throws: APNSConfigurationError.bothPrivateKeySources) { try configuration(both) }

        var unreadable = minimal
        unreadable.removeValue(forKey: "apns.private-key")
        unreadable["apns.private-key-path"] = "/nonexistent/apns.p8"
        do { _ = try configuration(unreadable) } catch let error as APNSConfigurationError {
            if case .unreadablePrivateKeyFile(let path, _) = error {
                #expect(path == "/nonexistent/apns.p8")
            } else {
                Issue.record("\(error)")
            }
        } catch { Issue.record("\(error)") }

        var bad = minimal
        bad["apns.private-key"] =
            "-----BEGIN PRIVATE KEY-----\nnot a key\n-----END PRIVATE KEY-----"
        do { _ = try configuration(bad) } catch let error as APNSConfigurationError {
            if case .invalidPrivateKey = error {} else { Issue.record("\(error)") }
        } catch { Issue.record("\(error)") }
    }

    @Test("an unknown environment and a non-positive timeout are refused")
    func badValues() {
        var environment = minimal
        environment["apns.environment"] = "staging"
        #expect(throws: (any Error).self) { try configuration(environment) }

        var timeout = minimal
        timeout["apns.request-timeout"] = "0s"
        #expect(throws: APNSConfigurationError.nonPositiveTimeout(.zero)) {
            try configuration(timeout)
        }
    }

    @Test("the description names everything but the key")
    func redaction() throws {
        let description = "\(try configuration(minimal))"
        #expect(description.contains("ABC123DEFG"))
        #expect(description.contains("com.example.app"))
        #expect(!description.contains("PRIVATE KEY"))
        #expect(description.contains("<REDACTED>"))
    }

    @Test(
        "the module provides a client built from the settings, and refuses bad ones at composition")
    func module() throws {
        let module = try AlulaAPNSModule(configuration: Configuration(values: minimal))
        #expect(module.client.configuration.topic == "com.example.app")
        #expect(module.service == nil)
        #expect(throws: (any Error).self) {
            try AlulaAPNSModule(configuration: Configuration())
        }
    }

    @Test("a device token is hex or nothing")
    func deviceToken() {
        #expect(DeviceToken(hex: "ABCDEF0123")?.hex == "abcdef0123")
        #expect(DeviceToken(hex: "") == nil)
        #expect(DeviceToken(hex: "xyz") == nil)
        #expect(DeviceToken(bytes: [0xAB, 0x01]).hex == "ab01")
    }
}

@Suite("apns.endpoint")
struct APNSEndpointTests {
    private func configuration(_ endpoint: String?) throws -> APNSConfiguration {
        var values = [
            "apns.key-id": "ABC123DEFG", "apns.team-id": "TEAM123456", "apns.topic": "com.example.app",
            "apns.private-key": ES256PrivateKey().pemRepresentation,
        ]
        values["apns.endpoint"] = endpoint
        return try APNSConfiguration(configuration: Configuration(values: values))
    }

    @Test("unset is Apple's gateway for the environment")
    func defaultGateway() throws {
        #expect(try configuration(nil).baseURL == "https://api.push.apple.com")
    }

    @Test("an emulator on loopback may be plain http; a trailing slash is dropped")
    func loopbackEmulator() throws {
        #expect(try configuration("http://127.0.0.1:56500/").baseURL == "http://127.0.0.1:56500")
        #expect(try configuration("https://apns-gateway.internal").baseURL == "https://apns-gateway.internal")
    }

    @Test("plain http anywhere else is refused: every request carries the provider token")
    func insecureRefused() {
        #expect(throws: APNSConfigurationError.self) { try configuration("http://apns-emulator.internal:8080") }
        #expect(throws: APNSConfigurationError.self) { try configuration("not a url") }
    }
}
