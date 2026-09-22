# Flight Channels

The stateful protocol layer between a raw WebSocket and topic-based
messaging: clients join named topics, exchange messages bidirectionally with
per-topic server handler logic, and receive fan-out from anything that
publishes to those topics. Scope modeled on Phoenix Channels, wire protocol
Flight's own.

It sits exactly between two things that already exist:

- **Below:** Flight Web's `WebSocketUpgradeHandler` owns the raw WebSocket.
  Channels is one.
- **Beside:** Flight PubSub does the fan-out. Channels routes and frames;
  PubSub delivers — on one node or twenty, invisibly.

What Channels adds is the per-connection, per-topic session protocol:
join/leave, routing to handlers, replies, heartbeats, reconnection.

## Adding this module

| | |
|---|---|
| **Trait** | `Web` |
| **Products** | `FlightChannels` |
| **Module** | `FlightChannelsModule.self` |
| **Pulls in** | `FlightPubSubModule` |

```swift
// Package.swift
dependencies: [
    .package(
        url: "https://github.com/Flight-Framework/flight.git",
        from: "0.28.0", traits: ["Web"]),
],
targets: [
    .executableTarget(
        name: "App",
        dependencies: [
            .product(name: "FlightCore", package: "flight"),
            .product(name: "FlightWeb", package: "flight"),
            .product(name: "FlightTransport", package: "flight"),
            .product(name: "FlightChannels", package: "flight"),
            .product(name: "FlightPubSub", package: "flight"),
        ],
        // Required. It scans this target for the Flight macros and writes
        // `flightComposeModules`; without it there is no composition root
        // to pass to `Flight.run`.
        plugins: [.plugin(name: "FlightRegistrationPlugin", package: "flight")]
    )
]
```

```swift
// Sources/App/Main.swift — *not* `main.swift`, which is top-level code and
// cannot coexist with @main.
import FlightChannels
import FlightCore
import FlightPubSub
import FlightTransport
import FlightWeb

@main
struct Main {
    static func main() async {
        await Flight.run(
            configuration: try Configuration.load(),
            modules: [
                FlightWebModule<FlightTransport>.self,
                FlightChannelsModule.self,
                AppModule.self,
            ],
            composedBy: flightComposeModules)
    }
}
```

A socket has to be served, so an application using Channels also runs a web
module and a transport — `FlightWebModule<FlightTransport>.self` — and mounts
the socket with a `@WebSocketRoute`. See `Docs/web.md`.

**Depend on the products of what it pulls in, too.** The generated composition
root names every module in the DAG, so a target that lists only
`FlightChannels` fails to build with `cannot find `FlightPubSubModule` in scope`
— from generated code, which is a confusing place to read it.

The `modules:` list names roots, not an order — the build resolves the
dependency DAG. A module you write can declare framework modules in its own
`dependencies`, in which case listing yours is enough.

## Targets

| Product | What | Depends on |
|---|---|---|
| `FlightChannels` | Server: `Channel`, `Socket`, `ChannelRouter`, `ChannelBroadcaster`, `ChannelSocketHandler`, `FlightChannelsModule` | Core, PubSub, Web |
| `FlightChannelsProtocol` | The wire protocol alone: `Envelope`, `JSONValue`, reserved events, error reasons, close codes | nothing |
| `FlightChannelsClient` | Swift reference client: `ChannelClient`, `ChannelHandle`, transport seam, reconnect-with-backoff-and-rejoin | Protocol, swift-log |
| `FlightChannelsTesting` | `InMemoryChannelTransport` (client ↔ in-process server, no socket), `ChannelWireClient` (raw-envelope driver) | the above + WebTesting |

The JS/TS reference client is
[flight-channels-js](https://github.com/Flight-Framework/flight-channels-js)
(`@flight-framework/channels` on npm) — same protocol, same versioning.

## Ordering and concurrency

**Envelopes are handled in order within a topic, and concurrently across
topics.** `flight.channels.max-concurrent-envelopes` (16 by default) bounds
how many a single socket may have in flight; set it to `1` for the older
behaviour, one envelope at a time socket-wide.

The frame loop used to handle each envelope completely before reading the
next, which made every topic on a connection share one queue: a channel
handler that took 200ms to answer a push on `room:1` delayed everything on
`room:2` behind it, for no reason other than that they arrived on the same
socket.

What is preserved is the ordering that a stateful protocol actually needs.
`flight:join` followed by a push on the same topic still arrive in that order
— including when the push is sent before the join has been answered — and a
`Channel` instance is never entered re-entrantly, so handlers keep the
serialization they were written against. What is given up is ordering
*between* topics, which are independent by construction: two envelopes on
different topics may complete in either order. Replies carry the `ref` they
answer, and the reference clients correlate on it rather than on arrival
order, so nothing downstream depends on the old guarantee.

Two consequences worth knowing:

- The in-flight bound is what the frame loop waits on when it is reached.
  Because inbound frames pull rather than buffer (see `Docs/web.md`), that
  wait reaches the socket — a client flooding one connection is slowed by TCP
  rather than handed unbounded work to queue.
- A teardown — `flight:close`, a heartbeat timeout, a protocol violation —
  cancels envelopes still in flight rather than draining them. Awaiting them
  would let one hung application handler block the very teardown that exists
  to get rid of it. A client that needs a push acknowledged before closing
  has the reply's `ref` to wait on.

## Backpressure and blast radius

A socket's outbound queue is bounded by
`flight.channels.outbound-buffer-size` (256 by default). It used to be
unbounded: a client that stopped reading — a backgrounded tab, a wedged
connection, a phone in a tunnel — accumulated every message published to its
topics with no ceiling, so one stalled subscriber could exhaust the server's
memory while the watchdog waited out a 60-second heartbeat timeout.

**Full closes the socket** (`4410`), rather than discarding frames. Discarding
was the original answer and it has a real argument behind it — a client behind
on a realtime feed wants current state, not a backlog it can never catch up on
— but it is undetectable from the other end. `Envelope` carries no sequence
number, so a dropped broadcast leaves no trace a client could notice: its view
goes silently wrong and it has no reason to suspect it. The server knew all
along (`Socket.droppedEnvelopeCount`, and a rate-limited warning); the client
never did.

A close it can see. The reference client's reconnect re-joins every topic and
delivers each channel's fresh `initialState`, which is exactly the
resynchronisation that dropping quietly denies it — and it needed no client
change, because a transport-level close already drives reconnect-and-rejoin.

`flight.channels.outbound-overflow: drop-oldest` restores the old behaviour,
and is right for a feed where only the latest value means anything — a cursor
position, a metrics tick, a progress bar. It is wrong wherever a message is an
*event* rather than a sample, because there the gap is the bug. An
unrecognised value for this key keeps the safe default rather than guessing;
a typo should not silently select lossy delivery.

Either way the close is ordered behind the queue: teardown finishes the
outbound stream and the writer drains what was already accepted before the
close frame goes out.

Nothing in the request path calls `precondition` any more. A reserved event
name reaching `Socket.push` or a broadcast is refused and logged. It used to
terminate the process — every other connected socket with it — because one
caller passed a bad name, and while the framework filters `flight:`-prefixed
events arriving in an envelope, an application deriving a name from client
*payload* is an ordinary pattern that reached the assertion.

`Socket.pushReserved` enforces the **opposite** rule — it refuses an event
that is *not* `flight:`-namespaced, because sending reserved events is its
entire purpose. It is `@_spi(FlightInternal)`, for Flight's own packages
layered on Channels (Presence today), and application code does not see it
without an SPI import.

## Server usage

```swift
import FlightChannels

struct RoomChannel: Channel {
    let broadcaster: ChannelBroadcaster

    // The join is the authorization gate. Identity was established
    // during the HTTP upgrade, before the WebSocket existed.
    func join(_ topic: String, socket: Socket) async -> JoinResult {
        guard let principal = socket.principal else { return .reject(.unauthenticated) }
        guard topic == "room:\(principal.subject)" || principal.hasRole("admin")
        else { return .reject(.forbidden) }
        return .ok(initialState: ["history": []])
    }

    func handle(_ event: InboundEvent, socket: Socket) async -> HandleResult {
        switch event.event {
        case "new_msg":
            // Channels never fans out itself — PubSub does.
            await broadcaster.broadcast(topic: event.topic, event: "new_msg", payload: event.payload)
            return .reply(["sent": true])
        default:
            return .error(reason: "unknown_event")
        }
    }

    func leave(_ topic: String, socket: Socket) async { /* optional */ }
}

struct AppModule: FlightModule {
    // Listed to *include* Channels in the application. It is not an ordering
    // constraint: this module declares channels, so Channels is built from
    // them and therefore built second.
    static var dependencies: [any FlightModule.Type] { [FlightChannelsModule.self] }

    // Channels are values this module holds. The composer collects `channels`
    // from every module declaring any and hands them all to
    // FlightChannelsModule, so a package the framework has never heard of
    // contributes channels without the application enumerating it.
    let channels: [ChannelRegistration]

    init(graph: FlightGraph) {
        let chat = graph.chatRepository
        self.channels = [
            // The broadcaster arrives per join, in the `ChannelContext`.
            // Everything else is closed over — a channel is handed what it
            // needs, not a container to look it up in.
            ChannelRegistration("room:*") { channel in
                RoomChannel(broadcaster: channel.broadcaster, chat: chat)
            },
            // Roles gate the pattern, before the channel is built.
            ChannelRegistration("admin:*", roles: [AppRole.admin]) { _ in
                AdminChannel()
            },
        ]
    }
}

@Controller
struct SocketController {
    @Inject var validator: any TokenValidator
    @Inject var sockets: ChannelSockets

    // Runs during the upgrade request. Return a principal, nil for
    // anonymous, or throw HTTPError(.unauthorized).
    @WebSocketRoute("/socket")
    func socket(_ context: RequestContext) async throws -> ChannelSocketHandler {
        let principal = try await verify(context.request.queryParam("token"))
        return sockets.handler(principal: principal)
    }
}
```

`channels.socketRoute("/socket") { ... }` builds the same upgrade route as a
value — a `RouteRegistration` the composition root hands `FlightWebModule` —
and suits a test harness or a spike. An application is better served by the
declared form: `@WebSocketRoute` is visible to the build-time scan and takes
its dependencies through the type (`@Inject`) rather than looking them up.

Topic patterns are exact (`"lobby"`), prefix-wildcard (`"room:*"`), or
catch-all (`"*"`); the most specific match wins, and duplicate or malformed
patterns fail bootstrap, not a join. Joining creates one `Channel` instance
per (socket, topic) — instances may hold per-membership state.

Anything can broadcast — a channel handler, a background job, another node:

```swift
// The broadcaster the channels module owns, wired in wherever it is needed:
let broadcaster = channels.broadcaster
await broadcaster.broadcast(topic: "room:42", event: "system", payload: ["msg": "hi"])
await broadcaster.broadcast(topic: "room:42", event: "new_msg", payload: p, excluding: senderSocket)
```

## Swift client usage

```swift
import FlightChannelsClient

let client = ChannelClient(url: url, transport: myTransport) // transport seam, see below
try await client.connect()

let room = client.channel("room:42")
let initialState = try await room.join()               // the join gate answers
let reply = try await room.push("new_msg", payload: ["body": "hi"])  // awaits flight:reply
try await room.send("typing", payload: ["on": true])   // fire-and-forget, ref: null

for await message in await room.messages() {            // server pushes, as a stream
    if message.isRejoin { /* fresh state after auto-reconnect */ }
}
```

Reconnection is client-driven: on a drop the client re-dials with
`ReconnectPolicy` backoff and rejoins every joined topic; the fresh initial
state arrives on `messages()` as a `flight:join` message. In-flight pushes
fail fast with `.disconnected`. Heartbeats run automatically; an unanswered
heartbeat is treated as a dead connection.

`ChannelClientTransport` is the one seam: implement `connect(to:)` over any
WebSocket (the E2E suite shows a hummingbird `WSClient` adapter in ~60
lines; `FlightChannelsTesting` ships the in-memory one).

## Wire protocol — the contract all three artifacts version together

One envelope, both directions, JSON text frames in v1:

```json
{ "ref": "7", "topic": "room:42", "event": "new_msg", "payload": { } }
```

- `ref` correlates request → reply; server pushes carry `ref: null`.
  All four keys are always present.
- Reserved events: `flight:join`, `flight:leave`, `flight:reply`,
  `flight:error` (payload `{"reason": "…"}`), `flight:heartbeat`,
  `flight:close`. Everything else routes to the channel's `handle`.
- Socket-level control events travel on the reserved topic `"flight"`,
  which can never be joined.
- Correlated success is `flight:reply` with the ref; correlated failure
  (join rejected, handler error) is `flight:error` with the ref.
- Close codes beyond RFC 6455's set: `4000` heartbeat timeout, `4408` write
  timeout (the peer stopped reading — still talking, no longer listening),
  `4410` outbound overflow (reading, but slower than the rate published to
  it — reconnect and resynchronise), `4400` protocol violation (undecodable
  envelope); binary frames close with
  `1003` (the binary codec is a later, negotiated addition). Every
  server-initiated close sends its code: the frame is written by the socket
  handler after its tasks are joined, because a close issued from inside one
  of them raced that task's own cancellation and reached the peer as `1006`.
- Server-produced error reasons: `unauthenticated`, `forbidden`,
  `unmatched_topic`, `already_joined`, `not_joined`, `too_many_topics`,
  `reserved_topic`, `handler_error`, `invalid_event`.

Channel traffic travels on the bus under `flight:channels:<topic>`, not on
the topic string a client joined — `ChannelProtocol.busTopic(_:)` is the
mapping, and Presence's own gossip has always been namespaced the same way
(`flight:presence`). It used to share the application's namespace, and both
directions of that collision were real: an application subscribing to
`shipment:42` received Channels' internal frames as opaque JSON, and one
*publishing* to `shipment:42` had its message dropped by every connected
socket's pump, with a warning each. Code that deliberately watches channel
traffic from outside subscribes through `ChannelProtocol.busTopic("room:42")`.

Semantics inherited from PubSub: at-most-once, no durability, no
replay. Per-socket inbound processing is serial (one envelope fully handled
before the next), and all outbound writes funnel through one per-socket
queue — a slow client never blocks a handler, and frames never interleave.

## Who may join what

Two gates, asking different questions, and both worth asking.

`roles:` on a `ChannelRegistration` answers **"may this kind of client
address this kind of topic at all"** — `admin:*` for admins. That is a
property of the pattern, so it is declared where the pattern is, checked
before the channel is constructed, and any-of within the list. It uses
`RouteRole`, the same type `@Controller` and the route macros take, so an
application declares one enum and uses it on both sides instead of keeping
two vocabularies in step. An anonymous socket gets `unauthenticated`, a
socket with the wrong roles gets `forbidden` — kept apart because "sign in"
and "you cannot do this" are different instructions.

`Channel.join` answers **"may *this* user join *this* topic"**. Membership of
`room:42` is data, not a role, and no declaration can express it. Roles do
not replace this check; they save a channel from being built for a caller who
could never have been admitted.

`roles:` on `@WebSocketRoute` is a third question again — whether this client
may open a socket at all — and guards the upgrade, not any topic on it.

## How many topics one socket may hold

`flight.channels.max-topics-per-socket` (64) bounds it. Every joined topic
costs a channel instance, a PubSub subscription, a fan-in task and an entry
in the session's per-topic ordering — five allocations, all driven by client
input, and nothing used to stop one connection asking for them without limit.
Over the bound, a join is refused with `too_many_topics`.

The bound counts **admissions, not settled joins**: a client that sends a
thousand joins in a burst has a thousand pending long before any has
finished, and a bound that only saw finished joins would not be a bound.
Leaving a topic frees its slot.

There is deliberately no "unlimited" spelling — unlimited is what this
replaced. An application needing more writes the larger number down.

For a considered policy rather than a blunt bound, `Socket.activeTopics` and
`Socket.activeTopicCount` are readable from inside `Channel.join`, so a plan
limit or a tenant quota can live where the application states its other
rules.

## Reconnection resynchronises; it does not replay

A client that reconnects re-joins every topic it wanted and takes each
channel's fresh `initialState`. **Nothing published while it was gone is
replayed**, and the protocol has no cursor to replay from — same boundary
Phoenix draws.

This became load-bearing when overflow started closing sockets rather than
dropping frames: reconnect-and-resync is now a routine path, not an
exceptional one. So `initialState` is doing more work than it looks like it
is. A channel whose `join` returns `.null` gives a reconnecting client nothing
to rebuild from, and the client cannot tell the difference between "nothing
happened" and "I missed everything" — which is the gap the overflow close was
meant to remove, reintroduced one level up.

The rule of thumb: `initialState` should carry whatever a client needs to
render the topic correctly having seen none of its history. If that is
expensive, it is still cheaper than being wrong, and the reconnect that asks
for it is rare.

## Configuration

| Key | Default | Meaning |
|---|---|---|
| `flight.channels.heartbeat-timeout-seconds` | `60` | A socket silent this long is closed (any frame counts as liveness) |
| `flight.channels.heartbeat-check-interval-seconds` | timeout ÷ 4 | Watchdog cadence |
| `flight.channels.outbound-buffer-size` | `256` | Queued frames per socket before `outbound-overflow` applies |
| `flight.channels.write-timeout-seconds` | `30` | One outbound frame taking longer than this closes the socket (`0` disables) |
| `flight.channels.max-concurrent-envelopes` | `16` | Envelopes in flight per socket; `1` means one at a time socket-wide |
| `flight.channels.outbound-overflow` | `close` | On a full outbound queue: `close` (4410, client resyncs) or `drop-oldest` |
| `flight.channels.max-topics-per-socket` | `64` | Topics one socket may hold; over it, a join is refused with `too_many_topics` |

A socket closed this way is told so with `4408` — as far as it can be. A peer
that has stopped reading entirely cannot receive a close frame either, so the
code is what a *slow* client sees and a wedged one never does; for that one the
timeout is about reclaiming the server's task and connection.

The write timeout is the bound the watchdog cannot supply. The watchdog counts
*inbound* frames as liveness, so a client that keeps heartbeating while never
reading looks perfectly alive to it — and the writer sits in `send` against a
TCP window that never opens, forever. Memory stays bounded by the outbound
queue; what accumulates is a task and a connection per such client, which is
slow resource exhaustion rather than fast.

Client side: `ChannelClientConfiguration(heartbeatInterval: .seconds(25),
pushTimeout: .seconds(10), reconnect: .exponentialBackoff())`.

## Testing support

```swift
let testClient = try TestClient(routes: [channels.socketRoute("/socket") { _ in nil }])
let transport = InMemoryChannelTransport(testClient: testClient)
let client = ChannelClient(url: URL(string: "flight-test:///socket")!, transport: transport)
```

Full stack — routing, upgrade, session, PubSub — in process. Every
`connect` dispatches a fresh upgrade, so reconnect/rejoin paths are
exercised for real. `ChannelWireClient` drives raw envelopes for
wire-level assertions. Multi-node behavior is testable with
`FlightPubSubTesting.InMemoryCluster` (see `MultiNodeTests`).

## Design notes

1. **`ChannelPrincipal` is a seam, not Security's `Principal`**. Channels'
   requirement is only "the join gate can read who this is", so it owns a
   two-member protocol (`subject`, `hasRole(_:)`) plus `BasicPrincipal` for
   simple cases, and takes no dependency on Security at all — a WebSocket
   layer should work with any notion of identity, or none.

   `FlightSecurityCore` ships, and the two meet in application code:

   ```swift
   extension Principal: @retroactive ChannelPrincipal {}
   ```

   The conformance is empty because `Principal` already has both members.
   Its validator then feeds the upgrade route's authentication
   closure, with no Channels change — which is what the seam was for. Same
   "seam, not engine" posture the package takes with transports and PubSub
   adapters.
2. **`JoinResult`/`HandleResult` are structs with static constructors**,
   not enums — the design's call sites (`.ok`, `.ok(initialState:)`) need
   an overload an enum case can't provide; the shapes are otherwise the
   doc's.
3. **`flight:error` answers correlated failures** (join rejected, handler
   error) carrying the originating `ref`; `flight:reply` is success-only.
   The doc lists both events without pinning the correlation rule; this
   split keeps "one obvious meaning per event" and lets clients reject the
   awaited promise/continuation directly.
4. **`HandleResult.none` on a ref-carrying message sends nothing** — the
   client's push times out. Mirrors Phoenix's `:noreply`: whether an event
   replies is the channel's contract with its client, not something the
   transport papers over. Clients ship `send`/fire-and-forget for
   known-no-reply events.
5. **The exit path never waits on the transport after a server-initiated
   close.** A half-open peer (the case heartbeats exist for) never
   completes the close handshake, so the frame loop is unblocked by task
   cancellation, not by the frame stream ending. Watchdog teardown
   finishes the outbound queue; the writer drains what was already queued
   (a graceful `flight:close` ack is flushed before the close frame), then
   everything is joined deterministically.
6. **`ChannelBroadcaster.broadcast(…, excluding:)`** — not in the doc, but
   the "tell everyone else" shape every chat-like handler wants. Carried
   as PubSub metadata (`flight.channels.origin`), filtered at the
   subscription pump, so it works across nodes unchanged.
7. **Rejoin state delivery** (client): after auto-reconnect, the fresh
   initial state is announced on the channel's message stream as a
   `flight:join` message (`ChannelMessage.isRejoin`). The original
   `join()` caller got its state as the return value; the stream is the
   only live surface after a silent reconnect.
