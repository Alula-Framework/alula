# ``FlightPubSub``

Publish/subscribe within a process, and across a cluster when an adapter is
configured.

## Overview

``PubSub`` is the whole interface: publish a ``Message`` to a topic,
subscribe to one. Everything else is which implementation is composed behind it.

```swift
@Inject var pubsub: any PubSub

await pubsub.publish(Message(topic: "orders", payload: data))

for await message in pubsub.subscribe("orders") {
    handle(message)
}
```

Neither call throws, and `subscribe` is synchronous — deliberately, so that
a subscription is in place the moment the call returns and cannot miss a
publish that races it.

``LocalPubSub`` delivers in-process and is what a single node uses.
``ClusteredPubSub`` wraps it with a ``DistributedPubSubAdapter`` so a publish
on one node reaches subscribers on every node.

**An adapter ships in flight-data.** `FlightPubSubValkey`'s
`ValkeyPubSubAdapter` implements ``DistributedPubSubAdapter`` over Valkey, and
`FlightPubSubValkeyModule` wires it, so a clustered deployment is configuration
rather than an afternoon's work. This page said "no adapter ships yet" for
several releases after that stopped being true.

The seam is still deliberately narrow — two methods, broadcast one message and
receive a stream of others' — so writing one against NATS or Redis remains
small. `FlightPubSubTesting`'s `InMemoryCluster` is a second conforming
implementation, and it exists to test the clustered paths rather than to run
them.

## Local first, clustered by configuration

A single-node application uses ``LocalPubSub`` and never learns that
clustering exists. Adding an adapter does not change a call site: the same
`publish` reaches the same subscribers plus the ones on other nodes.

That is why `FlightChannels` can build broadcast on top of this and stay
indifferent to deployment shape.

## Topics

### The interface

- ``PubSub``
- ``Message``

### Implementations

- ``LocalPubSub``
- ``ClusteredPubSub``
- ``DistributedPubSubAdapter``

### Hosting

- ``FlightPubSubModule``
- ``PubSubRelayService``
