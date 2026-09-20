# Flight

A modular server-side framework for Swift. Dependency injection and
application lifecycle at the bottom, HTTP and WebSockets above it, and
real-time layers — PubSub, Channels, Presence — on top of those.

One package, many products. Take only what you use: a JSON API needs
`FlightWeb` and `FlightTransport`; a collaborative app adds `FlightChannels`
and `FlightPresence`; a service behind an existing identity provider adds
`FlightSecurityCore`.

## Products

| Product | What it is |
| --- | --- |
| `FlightCore` | Modules, compile-time composition, application lifecycle. Everything else builds on this. |
| `FlightConfig` / `FlightConfigCore` | Layered configuration over swift-configuration; `FlightConfigCore` is the dependency-free parser and vocabulary. |
| `FlightWeb` | Routing, middleware, `RequestContext`, `Response`, WebSocket and SSE, and the `ServerTransport` seam. |
| `FlightTransport` | The default transport, wrapping HummingbirdCore. A peer of any third-party transport — the only target that knows what the transport wraps. |
| `FlightPubSub` | Topic-based publish/subscribe with a `DistributedPubSubAdapter` seam for cluster fan-out. |
| `FlightChannels` | Per-connection lifecycle over PubSub and Web: join, leave, push, broadcast. |
| `FlightPresence` | CRDT-merged "who is here", correct across a cluster without central coordination. |
| `FlightActuator` | Health probes always on; a topology dashboard only where a development environment is declared. |
| `FlightSecurityCore` | A resource server: validates tokens your identity provider issued. Bring your own auth. |
| `FlightScheduler` / `FlightCronCore` | Cron and interval jobs as annotated methods, with the schedule checked at build time. `FlightCronCore` is the dependency-free engine the macro validates with. |
| `*Protocol` | The wire shapes Channels and Presence share between server and client — the envelope, and the `flight:`-namespaced reserved events. Depend on this when writing a client in Swift against either. |
| `*Client` | Swift client halves: `FlightChannelsClient` for joining topics over a socket, `FlightPresenceClient` for applying presence state and diffs. |
| `*Testing` | Test support for Web, PubSub, Channels, and the Scheduler — in-memory transports, mock contexts, cluster harnesses, a clock that does not sleep. |

Per-product documentation lives in [Docs/](Docs/), and
[Docs/testing.md](Docs/testing.md) covers how to test an application built
on it.

## Getting started

```swift
.package(url: "https://github.com/Flight-Framework/flight.git", from: "0.22.1")
```

```swift
.target(name: "App", dependencies: [
    .product(name: "FlightWeb", package: "flight"),
    .product(name: "FlightTransport", package: "flight"),
])
```

## Traits

Merging eight packages into one would otherwise hand every consumer the union
of their dependencies. Two traits prevent that — SwiftPM resolves only what an
enabled trait reaches.

| Trait | Brings |
| --- | --- |
| `Web` | HTTP, WebSockets, SSE, Channels, Presence, actuator — Hummingbird, NIO, the TLS stack |
| `Security` | `FlightSecurityCore` — JWTKit, AsyncHTTPClient. Implies `Web`. |

Both are opt-in. Name what you want:

```swift
// An HTTP service.
.package(url: "https://github.com/Flight-Framework/flight.git",
         from: "0.22.1", traits: ["Web"])

// …with authentication.
.package(url: "https://github.com/Flight-Framework/flight.git",
         from: "0.22.1", traits: ["Security"])

// Just composition and lifecycle — 7 resolved dependencies instead of 29.
.package(url: "https://github.com/Flight-Framework/flight.git", from: "0.22.1")
```

**Swift 6.3 or later is required.** Through 6.2.x, SwiftPM did not resolve the
gated dependencies of a non-default trait enabled on a *versioned* dependency,
failing with *"exhausted attempts to resolve the dependencies graph"*
([#9286](https://github.com/swiftlang/swift-package-manager/issues/9286), fixed
by [#9269](https://github.com/swiftlang/swift-package-manager/pull/9269)).
Path dependencies always worked, so it appeared only once this package was
tagged. The manifest declares tools version 6.3 so an older toolchain says so
plainly instead of failing obscurely.

### Building this repository

A root build compiles every target regardless of traits, so it needs them all
enabled:

```
swift build --enable-all-traits
swift test  --enable-all-traits
```

A plain `swift build` here fails by design — the trait-gated targets find
their dependencies pruned. `CI/check-lean-consumer.sh` verifies the lean
configuration the only way that proves anything: by building a real consumer
and asserting no gated dependency reached it.

## Backends

Database and cache drivers deliberately live outside this package, in
`flight-data`, so that nothing here forces a Postgres or Valkey dependency
onto an application that does not use one.

## Requirements

| | Requirement |
| --- | --- |
| Swift | **6.3 or later** — see [Traits](#traits) for why 6.2.x will not do |
| Deployment target | macOS 15+, or Linux |
| Building on macOS | **the macOS 26 SDK (Xcode 26)** |
| Language mode | Swift 6, strict concurrency throughout |

The two macOS rows are different things, and the difference is the only
surprising entry here. `platforms: [.macOS(.v15)]` is the *deployment* target
and is accurate: what you build runs on macOS 15. But *compiling* it on a Mac
needs the macOS 26 SDK, because `apple/swift-configuration` imports
FoundationEssentials where it can and Foundation otherwise, and only the newer
SDK offers the former — on an older one it reaches for a `Data.bytes` that
Darwin's Foundation does not have.

Measured rather than assumed, both ways round: `.macOS(.v26)` on a `macos-26`
runner builds, and so does `.macOS(.v15)` on the same runner, which is why the
floor stayed where it is. On `macos-15` it fails.

> The macOS CI job **builds**; it does not run the test suite, which needs
> service containers macOS runners do not have. So macOS is a supported build
> platform, verified every push, and Linux is where the 1084 tests run.

## Testing

`swift test --enable-all-traits` — 1,000+ tests across 16 targets, no external
services required.

## License

MIT. See [LICENSE](LICENSE).
