import struct Foundation.Data

/// The unit of publish/subscribe.
///
/// - `topic` is opaque to PubSub: conventions like `"room:42"` belong to
///   consumers (Channels, Presence, Live); PubSub neither parses nor
///   validates structure.
/// - `payload` is opaque `Data`: serialization is the caller's concern.
///   PubSub has no business knowing whether it ships JSON, a LiveView diff,
///   or presence deltas.
/// - `metadata` carries small string annotations alongside the payload.
///   Keys prefixed `alula.pubsub.` are reserved for the transport itself
///   (see `ClusteredPubSub.originMetadataKey`).
///
/// `Codable` because a distributed adapter must put messages on a wire, and every adapter
/// re-inventing a frame for (topic, payload, metadata) would be the same code
/// three times. Conformance does NOT choose a wire format — adapters pick
/// their own encoder, or ignore Codable entirely.
public struct Message: Sendable, Equatable, Codable {
    /// Where it is published; subscribers of exactly this string receive it.
    public let topic: String
    /// The bytes, untouched by PubSub.
    public let payload: Data
    /// Small annotations; `alula.pubsub.*` keys are the transport's own.
    public let metadata: [String: String]

    /// A message; metadata defaults to none.
    public init(topic: String, payload: Data, metadata: [String: String] = [:]) {
        self.topic = topic
        self.payload = payload
        self.metadata = metadata
    }
}
