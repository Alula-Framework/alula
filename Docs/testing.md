# Testing an Alula application

The reason for the dependency injection is this page. An Alula application is
meant to be testable without a socket, a database, or a clock — you run the
real controllers, the real routing and the real middleware, and replace only
the parts that would reach outside the process.

There are three sizes of test. Most suites want the middle one.

| | What runs | Reach for it when |
|---|---|---|
| [Call the handler](#calling-a-handler-directly) | one method | the logic is the point and routing is not |
| [Routes under test](#routes-under-test--the-usual-choice) | the real controller, routing, middleware, DI | most of the time |
| [`AppModule` + `override`](#the-whole-application) | every module the application boots | you are testing the wiring itself |

## Routes under test — the usual choice

Build exactly the routes under test, giving each controller the fakes it
needs. Nothing else is wired, so the suite is not coupled to code it does not
exercise. A `@Controller`'s route factory constructs the controller per
request, so a fake is just a value passed in:

```swift
let repo = InMemoryUsers(users: [ada])
let client = try TestClient(routes: UserController.alulaRoutes { _ in
    UserController(users: UserService(repository: repo))
})

let response = await client.get("/users/\(ada.id)")
#expect(response.status == .ok)
```

`TestClient` dispatches **in process**. Routing, middleware, dependency
injection, request decoding and JSON encoding all run for real; there is no
socket and no port to collide with. These tests are fast because the network
is absent, not because the framework is stubbed.

A fake is a type that conforms. There is no mock framework and nothing
generated:

```swift
final class InMemoryUsers: UserRepositoryProtocol, Sendable {
    private let users = Mutex<[User]>([])
    var stored: [User] { users.withLock { $0 } }
    // …
}
```

Because it is a real object, a test can interrogate it afterwards — which is
how you assert on **effects** rather than only on what came back:

```swift
#expect(response.status == .badRequest)
#expect(users.stored.isEmpty, "validation must run before the write")
```

## Calling a handler directly

A `@Controller` is an ordinary struct. When routing is not what you are
testing, construct it and call the method:

```swift
let controller = UserController(users: InMemoryUsers(users: users))
let result = try await controller.list(.mock())
```

`RequestContext.mock` builds a context with whatever the handler needs —
path parameters, headers, a body.

> `@Controller` generates a memberwise initializer over the type's injected
> properties — `UserController(users:)` — which is what you call here and what
> the route factory calls per request.

## The whole application

Composing the real modules is the only way to test the **wiring** — and it
catches a class of bug the other two cannot, because building the graph is
where composition mistakes surface: an initializer that throws on real
configuration is invisible to a test that never composes. (Two modules
providing one type is caught earlier still — the generator refuses it, so the
build fails before any test runs.)

There is no "compose everything but swap one" — and none is needed. A
full-composition test composes the real modules:

```swift
let app = try Alula.assemble(configuration: config, modules: [appModule])
```

and a test that needs a fake builds the component under test directly (above),
with the fake passed to its initializer. The two are separate on purpose: one
proves the wiring, the other exercises behavior.

The demo carries a `BootstrapTests` suite that does nothing but compose its
real modules, for exactly this reason.

## Testing the layers

Each layer ships its own test support, and none of them need a server. One
product brings all of it:

```swift
// Package.swift
.testTarget(name: "AppTests", dependencies: [
    "App",
    .product(name: "AlulaTesting", package: "alula"),
])
```

```swift
import AlulaTesting
```

`AlulaTesting` re-exports every testing module the package's traits allow. A
module whose trait is off is left out along with its dependencies, so a
`traits: []` build gets the six trait-free modules and nothing from the HTTP
stack.

| Module | What it gives a test | Trait |
|---|---|---|
| `AlulaWebTesting` | `TestClient` (in-process requests and WebSockets), `RequestContext.mock`, `InMemoryTransport` | `Web` |
| `AlulaChannelsTesting` | `InMemoryChannelTransport` (a real `ChannelClient` against the real server, no socket), `ChannelWireClient` | `Web` |
| `AlulaSessionsTesting` | `RecordingSessionStore`: a working store that records every load, save and delete | — |
| `AlulaRateLimitTesting` | `RecordingRateLimitStore`: a working store on a clock the test moves, recording what was consumed; `misbehave()` for an outage | — |
| `AlulaQueueTesting` | `QueueTestHarness`: runs due jobs on demand with `drain()`, on a clock the test advances past retries | — |
| `AlulaMailTesting` | `RecordingMailTransport`: keeps what was sent, and fails on request | — |
| `AlulaPubSubTesting` | `InMemoryCluster` (several nodes, no wire), `RecordingAdapter` | — |
| `AlulaSchedulerTesting` | `TestSchedulerClock` (records sleeps, never sleeps), `StubJobCoordinator` | — |
| `AlulaHTTPClientTesting` | `StubHTTPTransport`: answers outbound requests from a closure and records them | `HTTPClient` |
| `AlulaAPNSTesting` | `RecordingAPNSTransport`: records each push and answers from a script | `APNS` |

Each module is also its own product. List one directly instead of
`AlulaTesting` when a build should compile only what it uses: a lean CI job,
or a package that tests one seam.

Three of the sections below are other packages' test support, which
`AlulaTesting` does not re-export: data and cache come from alula-data
(`AlulaDataTesting`, `AlulaCacheTesting`), and telemetry capture from
swift-telemetry (`TelemetryTesting`). List those products beside it.

### HTTP — `AlulaWebTesting`

`TestClient` for in-process requests, `RequestContext.mock` for direct handler
calls, and `InMemoryTransport` when you want the transport seam without a
socket.

### PubSub — `AlulaPubSubTesting`

`InMemoryCluster` stands in for the wire between nodes, so fan-out across a
cluster can be tested in a unit suite. Each call to `makeAdapter()` is another
node on it:

```swift
let cluster = InMemoryCluster()
let nodeA = cluster.makeAdapter()
let nodeB = cluster.makeAdapter()
```

`RecordingAdapter` is the simpler tool when you only need to see what was
published — its `broadcasts` property is every `Message` that went out.

### Channels — `AlulaChannelsTesting`

`InMemoryChannelTransport` connects a real `ChannelClient` to a real server
in-process — the whole join/push/reply protocol with no WebSocket.
`ChannelWireClient` drives raw envelopes when you are testing the protocol
itself rather than an application on top of it.

```swift
let client = ChannelClient(
    url: URL(string: "alula-test:///socket")!,
    transport: InMemoryChannelTransport(testClient: testClient, query: "token=…"))
```

### Presence — `AlulaPresenceClient`

`ChannelPresence` maintains the presence list from `alula:presence_state` and
`alula:presence_diff` messages, so a test asserts on the list rather than on
the wire.

### Data — alula-data's `AlulaDataTesting`

`InMemoryDataSource` and `InMemoryDataModule` stand in for a database.
`DataSourceConformance` is a contract suite every data source must satisfy —
run it against your own adapter and it will tell you where the behaviour
diverges.

### Sessions — `AlulaSessionsTesting`

`RecordingSessionStore` is a working store that also records every `load`,
`save` and `delete`, so a test can assert what a request did to its session
and read the record back. `SessionRuntime` takes a clock, so sliding
renewal and expiry are tested by moving it rather than by sleeping. A handler
called directly gets an empty session from `RequestContext.mock(session:)`.

### Rate limiting — `AlulaRateLimitTesting`

`RecordingRateLimitStore` is a working store with its own clock. A test
exhausts a limit, asserts the `429`, then calls `advance(by:)` instead of
waiting. `consumed` lists every key that was charged. `misbehave()` makes
every call throw, which exercises the middleware's fail-open path.

### Queue and mail — `AlulaQueueTesting`, `AlulaMailTesting`

`QueueTestHarness` runs queued jobs when the test says so. There is no
worker, no polling and no sleeping. `drain()` runs every due job in the order
a worker would, and a retry becomes due only once the test advances the
clock past it. `RecordingMailTransport` keeps every message a `Mailer` sent.
`fail(with:)` makes the next sends throw, so a queued delivery can be walked
through its retries:

```swift
let transport = RecordingMailTransport()
let mailer = Mailer(transport: transport, defaultFrom: try MailAddress("app@example.com"))
try await PasswordReset(mailer: mailer, jobs: harness.queue).request(for: ada, link: link)
await harness.drain()
#expect(transport.sent.first?.subject == "Reset your password")
```

### Scheduler — `AlulaSchedulerTesting`

`TestSchedulerClock` is a `SchedulerClock` that records each sleep and
returns at once. A question like "does the daily job fire on the day the
clocks go back" takes microseconds. `StubJobCoordinator` claims each run, or
declines or fails as told, to stand in for the cluster's single-runner
coordination.

### Outbound HTTP — `AlulaHTTPClientTesting`

`StubHTTPTransport` answers from a closure, or from a list of responses, and
records every request. Code that calls other services is tested with no
network:

```swift
let stub = StubHTTPTransport { request in
    request.url.path == "/forecast"
        ? .init(status: .ok, body: Data(#"{"high":21}"#.utf8))
        : .init(status: .notFound)
}
let weather = Weather(http: OutboundHTTPClient(transport: stub))
#expect(try await weather.forecast(for: "Oslo").high == 21)
```

### Push — `AlulaAPNSTesting`

`RecordingAPNSTransport` records every request, including its headers,
topic and payload. Pass it to `APNSClient(configuration:transport:)`. It
answers `200` until told otherwise. `respond(with:)` queues answers in order,
and `misbehave()` makes every call throw like a dropped connection.

### Cache — alula-data's `AlulaCacheTesting`

`RecordingCache` is a working in-memory cache that also records what was
asked of it, so a test can assert something *was cached* — or evicted —
rather than only that it returned the right value.

### Telemetry — swift-telemetry's `TelemetryTesting`

`TelemetryTest.capture(E.self) { … }` returns the events its body emitted,
typed. That includes events from child tasks and from requests made through
`TestClient`, and excludes every other test's, however many run in
parallel. Assert on what happened rather than on a metric: a sign-in
failure, a store outage, a span's stop metadata.

```swift
let attempts = await TelemetryTest.capture(SignInEvents.Attempt.self) {
    _ = try? await authenticator.authenticate(identifier: "ada", password: "wrong", clientAddress: nil)
}
#expect(attempts.map(\.metadata.outcome) == ["invalid_credentials"])
```

`capture(prefix:)` sees every event under a name, `captureSpans` sees every
phase, and `expectNoEmission(prefix:)` throws with whatever was emitted.
[telemetry.md](telemetry.md) has the rest.

## What still needs a real server

Nothing in this page does. Where a suite genuinely needs Postgres or Valkey —
testing a driver rather than an application — the packages that own those
drivers carry a `scripts/test.sh` that starts throwaway servers, runs the
suite and cleans up.

An application built on Alula should not need one: depend on a protocol,
pass a fake, and let the driver's own package prove the driver works.
