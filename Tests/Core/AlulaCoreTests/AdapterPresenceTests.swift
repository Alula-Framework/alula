import Configuration
import AlulaConfig
import Testing

@testable import AlulaCore

/// The guard that turns a silent fallback into a startup failure.
///
/// Its own doc comment describes the production symptom it exists to prevent
/// — "each node caches privately, and the first symptom is two users seeing
/// different numbers" — and nothing verified it fires. It is called from
/// `AlulaPubSubModule` and, in alula-data, from `AlulaCacheModule`.
@Suite("Unloaded adapters are refused at composition")
struct AdapterPresenceTests {

    private let candidates = [
        AdapterCandidate(configurationKey: "cache.valkey.url", module: "AlulaCacheValkeyModule")
    ]

    @Test("a configured adapter with no module loaded fails composition")
    func configuredButUnloadedThrows() {
        let configuration = Configuration(values: ["cache.valkey.url": "valkey://host"])
        #expect(throws: UnloadedAdapterError.self) {
            try configuration.requireNoUnloadedAdapter(feature: "cache", candidates: candidates)
        }
    }

    @Test("saying nothing is the ordinary single-node case, not an error")
    func absentKeyIsFine() throws {
        // The default has to stay free: the common deployment is one node and
        // must not have to name a module it does not use.
        try Configuration(values: [:])
            .requireNoUnloadedAdapter(feature: "cache", candidates: candidates)
    }

    @Test("the message names the key, the module, and what to do")
    func errorIsActionable() {
        let error = UnloadedAdapterError(
            feature: "cache", configurationKey: "cache.valkey.url",
            module: "AlulaCacheValkeyModule")
        let text = error.description
        #expect(text.contains("cache.valkey.url"))
        #expect(text.contains("AlulaCacheValkeyModule"))
        // An operator needs both exits, because either can be the right one.
        #expect(text.contains("Add AlulaCacheValkeyModule"))
        #expect(text.contains("remove"))
    }

    @Test("the first configured candidate is the one reported")
    func firstConfiguredCandidateWins() throws {
        let configuration = Configuration(values: ["pubsub.nats.url": "nats://host"])
        do {
            try configuration.requireNoUnloadedAdapter(
                feature: "pubsub",
                candidates: [
                    AdapterCandidate(configurationKey: "pubsub.valkey.url", module: "Valkey"),
                    AdapterCandidate(configurationKey: "pubsub.nats.url", module: "NATS"),
                ])
            Issue.record("expected a throw")
        } catch let error as UnloadedAdapterError {
            #expect(error.module == "NATS")
        }
    }

    @Test("a key that cannot be decoded still counts as configured")
    func unreadableKeyCountsAsPresent() {
        // `isPresent` catches rather than propagates, deliberately: an array
        // under a key the adapter reads as a string throws on resolve. The
        // operator still wrote something there, which is the whole signal —
        // treating a decode failure as "absent" would hand them the silent
        // fallback this guard exists to prevent.
        let provider = InMemoryProvider(
            name: "test",
            values: ["cache.valkey.url": ProviderValue(.stringArray(["a", "b"]), isSecret: false)])
        #expect(throws: UnloadedAdapterError.self) {
            try Configuration(providers: [provider])
                .requireNoUnloadedAdapter(feature: "cache", candidates: candidates)
        }
    }
}
