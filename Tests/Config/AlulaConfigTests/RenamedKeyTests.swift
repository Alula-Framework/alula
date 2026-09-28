import Foundation
import Testing

@testable import AlulaConfig

/// A renamed key's former spelling is refused, never read as a fallback
/// (subtraction R14). The variable layer is the one place two spellings can
/// be one entry, so most of this is about telling those apart.
@Suite("getIfPresent(_:formerly:) refuses former spellings")
struct RenamedKeyTests {
    private func load(yaml: String, environment: [String: String] = [:]) throws -> Configuration {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alula-renamed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try yaml.write(
            to: directory.appendingPathComponent("alula.yaml"), atomically: true, encoding: .utf8)
        return try Configuration.load(from: directory, processEnvironment: environment)
    }

    @Test("the current spelling is read, and absence is nil")
    func currentSpelling() throws {
        let configuration = Configuration(values: ["a.new-key": "1"])
        #expect(try configuration.getIfPresent("a.new-key", formerly: ["a.old_key"], as: Int.self) == 1)
        #expect(try Configuration().getIfPresent("a.new-key", formerly: ["a.old_key"], as: Int.self) == nil)
    }

    @Test("a former spelling is refused, alone or beside the current one")
    func formerSpellingRefused() {
        let refusal = ConfigError.renamedKey(
            formerKey: "a.old_key", currentKey: "a.new-key", provider: "TestConfigSource")
        #expect(throws: refusal) {
            try Configuration(values: ["a.old_key": "1"])
                .getIfPresent("a.new-key", formerly: ["a.old_key"], as: Int.self)
        }
        // Even the same value: one of the two lines is dead, and the YAML
        // layers hold keys exactly as written.
        #expect(throws: refusal) {
            try Configuration(values: ["a.new-key": "1", "a.old_key": "1"])
                .getIfPresent("a.new-key", formerly: ["a.old_key"], as: Int.self)
        }
    }

    @Test("a former spelling in alula.yaml is refused, naming the file")
    func yamlRefused() throws {
        let configuration = try load(yaml: "pubsub:\n  node_id: api-1\n")
        #expect(
            throws: ConfigError.renamedKey(
                formerKey: "pubsub.node_id", currentKey: "pubsub.node-id", provider: "alula.yaml")
        ) {
            try configuration.getIfPresent(
                "pubsub.node-id", formerly: ["pubsub.node_id"], as: String.self)
        }
    }

    /// `pubsub.node_id` and `pubsub.node-id` are both ALULA_PUBSUB_NODE_ID:
    /// that variable is the new key, and must not be refused as the old one.
    @Test("a variable that spells both keys is read as the current one")
    func foldedVariableRead() throws {
        let configuration = try load(
            yaml: "server:\n  port: 8080\n", environment: ["ALULA_PUBSUB_NODE_ID": "api-2"])
        #expect(
            try configuration.getIfPresent(
                "pubsub.node-id", formerly: ["pubsub.node_id"], as: String.self) == "api-2")
    }

    @Test("a variable that spells only the former key is refused")
    func formerVariableRefused() throws {
        let configuration = try load(
            yaml: "server:\n  port: 8080\n",
            environment: ["ALULA_ALULA_PRESENCE_NODE_NAME": "web-1"])
        #expect(
            throws: ConfigError.renamedKey(
                formerKey: "alula.presence.node-name", currentKey: "presence.node-name",
                provider: "the environment variable ALULA_ALULA_PRESENCE_NODE_NAME")
        ) {
            try configuration.getIfPresent(
                "presence.node-name", formerly: ["alula.presence.node-name"], as: String.self)
        }
    }

    @Test("the positive helpers refuse through the same check")
    func positiveHelpersRefuse() {
        let configuration = Configuration(values: ["old.seconds": "5"])
        let refusal = ConfigError.renamedKey(
            formerKey: "old.seconds", currentKey: "a.seconds", provider: "TestConfigSource")
        #expect(throws: refusal) {
            try configuration.positiveSeconds("a.seconds", formerly: ["old.seconds"])
        }
        #expect(throws: refusal) {
            try configuration.secondsOrDisabled("a.seconds", formerly: ["old.seconds"])
        }
    }

    @Test("the message names both keys and the layer, and says the old one is not read")
    func message() {
        let error = ConfigError.renamedKey(
            formerKey: "pubsub.node_id", currentKey: "pubsub.node-id", provider: "alula.yaml")
        #expect(
            error.description
                == "Configuration key 'pubsub.node_id' is set in alula.yaml, but it was renamed "
                + "'pubsub.node-id' and the old spelling is no longer read. Rename it to "
                + "'pubsub.node-id'; Alula stops here rather than start without the value you set.")
    }
}
