import FlightConfig
import Testing

@testable import FlightCore

/// The guard that turns a silent fallback into a startup failure.
///
/// Its own doc comment describes the production symptom it exists to prevent
/// — "each node caches privately, and the first symptom is two users seeing
/// different numbers" — and nothing verified it fires. It is called from
/// `FlightPubSubModule` and, in flight-data, from `FlightCacheModule`.
@Suite("Unloaded adapters are refused at composition")
struct AdapterPresenceTests {

    private let candidates = [
        AdapterCandidate(configurationKey: "cache.valkey.url", module: "FlightCacheValkeyModule")
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
            module: "FlightCacheValkeyModule")
        let text = error.description
        #expect(text.contains("cache.valkey.url"))
        #expect(text.contains("FlightCacheValkeyModule"))
        // An operator needs both exits, because either can be the right one.
        #expect(text.contains("Add FlightCacheValkeyModule"))
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

    // Not covered here: `isPresent` catches a failing resolve and reports
    // the key as *present* — "the operator wrote something there, which is
    // the whole signal". Proving it needs a provider holding a non-scalar,
    // and `ConfigValue` cannot be named from this target: the
    // swift-configuration module and `FlightConfig.Configuration` share the
    // name `Configuration`, so the qualified form resolves to the struct.
    // The behaviour is the documented one and worth a test from inside the
    // Config target, where both names resolve.
}
