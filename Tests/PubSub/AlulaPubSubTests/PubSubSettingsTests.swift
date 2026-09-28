import AlulaCore
import Foundation
import Testing

@testable import AlulaPubSub

/// The module's deployment knobs, which until 0.13.0 were `init` parameters
/// no deployment could reach: both public entry points take
/// `[any AlulaModule.Type]` and instantiate with `init()`, so buffering,
/// node identity and the broadcast timeout were unreachable — and the
/// documented example passed a module instance and did not compile.
@Suite("PubSub settings")
struct PubSubSettingsTests {

    // MARK: Buffering

    @Test("unbounded is the default when nothing is configured")
    func bufferingDefaultsToUnbounded() throws {
        let settings = try PubSubSettings(configuration: Configuration())
        #expect(settings.bufferingPolicy == .unbounded)
        #expect(settings.nodeID == nil)
        #expect(settings.broadcastTimeout == .after(.seconds(5)))
    }

    @Test(
        "a bound and a count parse",
        arguments: [
            ("newest:1024", PubSubBufferingPolicy.bufferingNewest(1024)),
            ("oldest:512", .bufferingOldest(512)),
            ("unbounded", .unbounded),
            ("  NEWEST : 16  ", .bufferingNewest(16)),
        ])
    func bufferingParses(_ written: String, _ expected: PubSubBufferingPolicy) throws {
        let settings = try PubSubSettings(
            configuration: Configuration(values: [PubSubSettings.bufferingKey: written]))
        #expect(settings.bufferingPolicy == expected)
    }

    /// Loudly, not silently: a node told to bound its buffers and quietly
    /// running unbounded is the failure the setting exists to prevent.
    @Test(
        "a malformed buffering policy fails bootstrap",
        arguments: ["newest", "newest:0", "newest:-4", "sideways:10", "1024", ""])
    func malformedBufferingThrows(_ written: String) {
        #expect(throws: (any Error).self) {
            try PubSubSettings(
                configuration: Configuration(values: [PubSubSettings.bufferingKey: written]))
        }
    }

    // MARK: Broadcast timeout

    @Test("a duration parses, and `never` is distinct from absent")
    func broadcastTimeoutParses() throws {
        let bounded = try PubSubSettings(
            configuration: Configuration(values: [PubSubSettings.broadcastTimeoutKey: "250ms"]))
        #expect(bounded.broadcastTimeout == .after(.milliseconds(250)))
        #expect(bounded.broadcastTimeout.duration == .milliseconds(250))

        let forever = try PubSubSettings(
            configuration: Configuration(values: [PubSubSettings.broadcastTimeoutKey: "never"]))
        #expect(forever.broadcastTimeout == .never)
        // The distinction a bare `Duration?` could not carry: "wait forever"
        // and "not configured" are different answers.
        #expect(forever.broadcastTimeout.duration == nil)
    }

    /// Relay #33: the keys shipped snake_case, unlike every other Alula key.
    @Test("kebab-case keys are read, and the snake_case ones they replaced are refused")
    func keySpellings() throws {
        let current = try PubSubSettings(configuration: Configuration(values: [
            "pubsub.node-id": "api-3", "pubsub.broadcast-timeout": "1s",
        ]))
        #expect(current.nodeID == "api-3")
        #expect(current.broadcastTimeout == .after(.seconds(1)))

        #expect(throws: ConfigError.renamedKey(
            formerKey: "pubsub.node_id", currentKey: "pubsub.node-id", provider: "TestConfigSource")
        ) {
            try PubSubSettings(configuration: Configuration(values: ["pubsub.node_id": "api-4"]))
        }
        #expect(throws: ConfigError.renamedKey(
            formerKey: "pubsub.broadcast_timeout", currentKey: "pubsub.broadcast-timeout",
            provider: "TestConfigSource")
        ) {
            try PubSubSettings(configuration: Configuration(values: ["pubsub.broadcast_timeout": "2s"]))
        }
        // Setting the new key too does not make the old line harmless.
        #expect(throws: ConfigError.renamedKey(
            formerKey: "pubsub.node_id", currentKey: "pubsub.node-id", provider: "TestConfigSource")
        ) {
            try PubSubSettings(configuration: Configuration(values: [
                "pubsub.node-id": "new", "pubsub.node_id": "old",
            ]))
        }
    }

    /// `node-id` and `node_id` are one environment variable: the refusal
    /// must not fire for the new key's own spelling.
    @Test("ALULA_PUBSUB_NODE_ID is the new key's variable, and is read")
    func environmentVariableSpelling() throws {
        let settings = try PubSubSettings(configuration: Configuration.load(
            from: try yamlDirectory("pubsub:\n  buffering: unbounded\n"),
            processEnvironment: [
                "ALULA_PUBSUB_NODE_ID": "api-5", "ALULA_PUBSUB_BROADCAST_TIMEOUT": "3s",
            ]))
        #expect(settings.nodeID == "api-5")
        #expect(settings.broadcastTimeout == .after(.seconds(3)))
    }

    @Test("a YAML node_id is refused even with ALULA_PUBSUB_NODE_ID set")
    func yamlSnakeCaseIsRefused() throws {
        let directory = try yamlDirectory("pubsub:\n  node_id: api-6\n")
        #expect(throws: ConfigError.renamedKey(
            formerKey: "pubsub.node_id", currentKey: "pubsub.node-id", provider: "alula.yaml")
        ) {
            try PubSubSettings(configuration: Configuration.load(
                from: directory, processEnvironment: [:]))
        }
        // The variable wins resolution, but alula.yaml still has the line.
        #expect(throws: ConfigError.renamedKey(
            formerKey: "pubsub.node_id", currentKey: "pubsub.node-id", provider: "alula.yaml")
        ) {
            try PubSubSettings(configuration: Configuration.load(
                from: directory, processEnvironment: ["ALULA_PUBSUB_NODE_ID": "api-7"]))
        }
    }

    private func yamlDirectory(_ base: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pubsub-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try base.write(
            to: directory.appendingPathComponent("alula.yaml"), atomically: true, encoding: .utf8)
        return directory
    }

    @Test("a bare number is rejected, as everywhere else a Duration is read")
    func broadcastTimeoutRequiresAUnit() {
        #expect(throws: (any Error).self) {
            try PubSubSettings(
                configuration: Configuration(values: [PubSubSettings.broadcastTimeoutKey: "30"]))
        }
    }

    // MARK: Reaching the pool

    @Test("the configured policy reaches LocalPubSub through the module")
    func settingsReachTheComponent() throws {
        let configuration = Configuration(values: [
            PubSubSettings.bufferingKey: "oldest:8",
            PubSubSettings.nodeIDKey: "api-3",
        ])
        // Building the module reads and validates the settings; a malformed
        // value would throw here. The local core and the bus both exist as
        // values the module holds — no container to resolve them from.
        let module = try AlulaPubSubModule(configuration: configuration)
        #expect(module.bus is LocalPubSub)
        _ = module.local
    }
}
