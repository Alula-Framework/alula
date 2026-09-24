# Alula

A modular server-side framework for Swift. Dependency injection and
application lifecycle at the bottom, HTTP and WebSockets above it, and
real-time layers — PubSub, Channels, Presence — on top of those.

One package, many products. Take only what you use: a JSON API needs
`AlulaWeb` and `AlulaTransport`; a collaborative app adds `AlulaChannels`
and `AlulaPresence`; a service behind an existing identity provider adds
`AlulaSecurityCore`.

## Products

| Product | What it is |
| --- | --- |
| `AlulaCore` | Modules, compile-time composition, application lifecycle. Everything else builds on this. |
| `AlulaConfig` / `AlulaConfigCore` | Layered configuration over swift-configuration; `AlulaConfigCore` is the dependency-free parser and vocabulary. |
| `AlulaWeb` | Routing, middleware, `RequestContext`, `Response`, WebSocket and SSE, and the `ServerTransport` seam. |
| `AlulaTransport` | The default transport, wrapping HummingbirdCore. A peer of any third-party transport — the only target that knows what the transport wraps. |
| `AlulaPubSub` | Topic-based publish/subscribe with a `DistributedPubSubAdapter` seam for cluster fan-out. |
| `AlulaChannels` | Per-connection lifecycle over PubSub and Web: join, leave, push, broadcast. |
| `AlulaPresence` | CRDT-merged "who is here", correct across a cluster without central coordination. |
| `AlulaSessions` | Server-side sessions: the store seam and the bounded in-memory default. The middleware and `context.session` are `AlulaWeb`'s. |
| `AlulaRateLimit` | A GCRA rate limiter and its store seam. Not an HTTP concern: `AlulaWeb`'s `RateLimiting` middleware is one consumer, a login throttle is another. |
| `AlulaWeb`'s `TrustedProxies` | The real client address behind a reverse proxy, resolved from `X-Forwarded-For` only as far as a configured trusted range reaches. |
| `AlulaWeb`'s `CSRFProtection` | Refuses a state-changing request without the session's own token. The synchronizer pattern, keyed off `AlulaSessions`. |
| `AlulaWeb`'s `SecurityHeaders` | `nosniff`, `DENY` and a strict referrer policy on every response by default; HSTS and CSP when configured. Applied after every lane, so no route can drop them. |
| `AlulaActuator` | Health probes always on; a topology dashboard only where a development environment is declared, and behind authentication and a role when configured. |
| `AlulaSecurityCore` | Validates tokens your identity provider issued, and signs people in: against your own accounts (`PasswordSignIn`, throttled, Argon2id) or any OpenID Connect provider (`OIDCSignIn`), behind one `SignInProvider` seam so switching is a change to the module list. |
| `AlulaAPNS` | Apple Push Notification service client: provider tokens, HTTP/2, a typed answer per push. Requires the `APNS` trait. |
| `AlulaTelemetryBridges` | Reporting for [swift-telemetry](https://github.com/Alula-Framework/swift-telemetry)'s typed events — which Alula's own subsystems emit — to swift-metrics, swift-distributed-tracing and swift-log, wired from `telemetry.*` by `AlulaTelemetryModule`, which the Web, Sessions, Security and APNs modules bring with them. |
| `AlulaScheduler` / `AlulaCronCore` | Cron and interval jobs as annotated methods, with the schedule checked at build time. `AlulaCronCore` is the dependency-free engine the macro validates with. |
| `AlulaQueue` / `AlulaQueueTesting` | Background jobs: enqueue from anywhere, run in a worker at least once, retried with backoff, dead-lettered when they never succeed. Durable with alula-data's `AlulaQueuePostgres`. See [Docs/queue.md](Docs/queue.md). |
| `AlulaMail` / `AlulaMailSMTP` / `AlulaMailTesting` | Email: a transport seam, header-injection-proof messages, MIME rendering, delivery through the job queue, and an SMTP client (trait `SMTP`). See [Docs/mail.md](Docs/mail.md). |
| `AlulaHTTPClient` / `AlulaHTTPClientTesting` | Calling other services: timeouts, retries only where safe, trace propagation, response caps (trait `HTTPClient`). See [Docs/http-client.md](Docs/http-client.md). |
| `*Protocol` | The wire shapes Channels and Presence share between server and client — the envelope, and the `alula:`-namespaced reserved events. Depend on this when writing a client in Swift against either. |
| `*Client` | Swift client halves: `AlulaChannelsClient` for joining topics over a socket, `AlulaPresenceClient` for applying presence state and diffs. |
| `*Testing` | Test support for Web, PubSub, Channels, Sessions, rate limiting, APNs, and the Scheduler — in-memory transports, mock contexts, cluster harnesses, a clock that does not sleep. Telemetry capture is swift-telemetry's `TelemetryTesting`. |

Per-product documentation lives in [Docs/](Docs/), and
[Docs/testing.md](Docs/testing.md) covers how to test an application built
on it.

## Getting started

```swift
.package(url: "https://github.com/Alula-Framework/alula.git", from: "0.36.0")
```

```swift
.target(name: "App", dependencies: [
    .product(name: "AlulaWeb", package: "alula"),
    .product(name: "AlulaTransport", package: "alula"),
])
```

## Traits

Merging eight packages into one would otherwise hand every consumer the union
of their dependencies. Traits prevent that — SwiftPM resolves only what an
enabled trait reaches.

| Trait | Brings |
| --- | --- |
| `Web` | HTTP, WebSockets, SSE, Channels, Presence, actuator — Hummingbird, NIO, the TLS stack. Implies `Telemetry`. |
| `Security` | `AlulaSecurityCore` — JWTKit, AsyncHTTPClient, the Argon2 reference implementation. Implies `Web`. |
| `APNS` | `AlulaAPNS` — JWTKit, AsyncHTTPClient. Implies `Telemetry` and nothing else; a push-sending worker needs no HTTP server. |
| `Telemetry` | `AlulaTelemetryBridges` — swift-telemetry, swift-metrics and swift-distributed-tracing. |

All are opt-in. Name what you want:

```swift
// An HTTP service.
.package(url: "https://github.com/Alula-Framework/alula.git",
         from: "0.36.0", traits: ["Web"])

// …with authentication.
.package(url: "https://github.com/Alula-Framework/alula.git",
         from: "0.36.0", traits: ["Security"])

// Just composition and lifecycle — 7 resolved dependencies instead of 30.
.package(url: "https://github.com/Alula-Framework/alula.git", from: "0.36.0")
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
`alula-data`, so that nothing here forces a Postgres or Valkey dependency
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
