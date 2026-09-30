import AlulaCore
import class Foundation.ProcessInfo
import ServiceLifecycle

/// Owns PubSub: the local core, the bus consumers use, and — when the
/// deployment is clustered — the relay that feeds it.
///
/// - `local` is the concrete core, for anything that specifically wants
///   intra-node-only fan-out.
/// - `bus` is what consumers (Channels, Presence, app code) use: the local
///   core on a single node, a `ClusteredPubSub` wrapping it when an adapter
///   was supplied. Consumers never know which.
///
/// **Composed by argument, not by presence.** An adapter module provides a
/// `DistributedPubSubAdapter`, and that is all it does. This module takes
/// it, builds the bus around it, and owns the relay, so an adapter module
/// cannot forget to run `PubSubRelayService` and leave a cluster that
/// silently never relays. See `Docs/pubsub.md`, "Writing an adapter module".
public struct AlulaPubSubModule: AlulaModule {

    /// The concrete local core.
    public let local: LocalPubSub

    /// What consumers use.
    public let bus: any PubSub

    /// Non-nil exactly when an adapter was supplied — which is what decides
    /// whether there is a relay to run.
    private let clustered: ClusteredPubSub?

    /// Buffering, node identity and the broadcast timeout come from
    /// `alula.yaml` (`pubsub.buffering`, `pubsub.node-id`,
    /// `pubsub.broadcast-timeout`); `Docs/pubsub.md` documents the keys.
    /// The pre-0.60 snake_case spellings (`pubsub.node_id`,
    /// `pubsub.broadcast_timeout`) are refused with ALU-CONFIG-5014.
    ///
    /// `adapter` nil means single node — the 90% case. A parameter rather
    /// than a runtime lookup because "is there an adapter in this
    /// deployment" is a fact about how the application was composed, which
    /// the composition root knows.
    ///
    /// - Throws: A configuration error for a bad `pubsub.*` value, or when
    ///   configuration names an adapter (`pubsub.valkey.url`, say) that no
    ///   included module provides.
    public init(
        configuration: Configuration,
        adapter: (any DistributedPubSubAdapter)? = nil
    ) throws {
        let settings = try PubSubSettings(configuration: configuration)
        let local = LocalPubSub(bufferingPolicy: settings.bufferingPolicy.streamPolicy)
        self.local = local

        guard let adapter else {
            // Configuration naming an adapter nobody loaded would otherwise
            // give every node its own private fan-out, with no symptom until
            // production.
            try configuration.requireNoUnloadedAdapter(
                feature: "PubSub",
                candidates: [
                    AdapterCandidate(
                        configurationKey: "pubsub.valkey.url",
                        module: "AlulaPubSubValkeyModule (alula-data)"),
                    AdapterCandidate(
                        configurationKey: "pubsub.adapter.url",
                        module: "a DistributedPubSubAdapter module"),
                ])
            self.clustered = nil
            self.bus = local
            return
        }
        let clustered = ClusteredPubSub(
            local: local, adapter: adapter,
            nodeID: settings.nodeID ?? ProcessInfo.processInfo.hostName,
            broadcastTimeout: settings.broadcastTimeout.duration)
        self.clustered = clustered
        self.bus = clustered
    }

    /// Unavailable: a hand-written call is a compile error saying how to
    /// build this module, and the composer never counts it as a candidate.
    @available(*, unavailable, message: "AlulaPubSubModule takes its configuration in init(configuration:adapter:), so it cannot be instantiated from its type. Pass `composedBy: alulaComposeModules` to Alula.run — `alula new` writes that argument — or construct the module yourself and use the entry point taking module instances.")
    public init() { fatalError("unavailable") }

    /// The relay, when clustered; nil on a single node. It belongs here rather than to the adapter
    /// module because this is what has both halves — the adapter to drain and
    /// the local core to drain it into. An adapter module used to have to
    /// remember to expose it, and a cluster whose author forgot relayed
    /// nothing, silently.
    public var service: (any Service)? {
        clustered.map { PubSubRelayService(clustered: $0) }
    }
}
