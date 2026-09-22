# flight-core

Dependency injection and application bootstrap for Swift servers.

Components declare themselves with an attribute. A build plugin wires them
together and checks the graph at compile time. Bootstrap builds every module
and component once, at composition, and runs your services under a
`ServiceGroup`.

```swift
@Service
final class UserService: Sendable {
    @Inject let repository: any UserRepository
    @ConfigValue("features.signup_enabled", default: true) let signupEnabled: Bool
}

@main
struct App {
    static func main() async {
        await Flight.run(
            configuration: try Configuration.load(),
            modules: [WebModule.self, DataModule.self],
            composedBy: flightComposeModules
        )
    }
}
```

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/Flight-Framework/flight.git", from: "0.28.0")
]
```

```swift
.target(
    name: "MyApp",
    dependencies: [.product(name: "FlightCore", package: "flight")],
    plugins: [.plugin(name: "FlightRegistrationPlugin", package: "flight")]
)
```

Requires **Swift 6.3+** — 6.2.x cannot resolve this package's traits.
Runs on Linux and macOS 15+; building on a Mac needs the macOS 26 SDK,
for the reason in the [README](../README.md#requirements).

`Flight.run` is `bootstrap` that does not throw: it starts the application,
and if it *cannot* start it prints why and exits `1`. A `main` that throws
instead reports the same message under `Fatal error: Error raised at top
level`, a backtrace and a `Signal 4` — a configuration typo dressed as a
crash. `bootstrap` remains for embedders that want the error rather than the
exit.

## Two phases, and why it matters

The graph is built all at once, then never changes.

**Composition.** At startup the generated composition root builds every module
and component once, in dependency order, and wires what each provides into
whatever injects it — by type. Single-threaded, by construction — no
concurrency exists yet.

**Running.** From that point the graph is immutable, so reaching a dependency
is a stored-property read with no lock, safe from any thread, and a
constructor that was going to fail has already failed — during startup, where
you can see it.

Building the whole graph once, up front, is what lets a request reach its
dependencies with no lookup at all, and it is why the graph is fixed after
composition rather than something a running application adds to.

## Components should be `Sendable`

A singleton is built once and shared for the whole application, reachable from
every thread that serves a request. A mutable, non-`Sendable` component shared
between two actors is a data race with no diagnostic — composition is exactly
the place where shared state gets shared, so the requirement belongs here.

```swift
@Service final class UserService: Sendable { }        // ✅
@Service final class Counter { var count = 0 }        // ⚠️ compiles, and races
```

**This is a convention, not something the compiler checks for you.** That
enforcement left with the container in 0.17.0. `@Service` adds an initializer
and nothing else — no conformance, no constraint — so a component is only
forced to be `Sendable` when something that is itself `Sendable` stores it.
The second line above was compiled to check this claim, and it builds cleanly.

Declare `Sendable` and the compiler will check the inside of the type for you.
Omit it and nothing will remind you.

For per-request mutable state, carry it on `RequestContext` — it rides the
request as a typed value, not a shared component.

## Lifetimes

Singleton is the only lifetime: a component is built **once**, by the
composition root, and shared for the application's lifetime. There is no
`.scoped` or `.transient` — per-request state rides `RequestContext`, and a
pooled connection is leased per operation, so nothing needed them and their
captive-dependency class of bug went with them. See <doc:Lifetimes>.

## Compile-time wiring

The build plugin scans your sources, generates the registration code, and
checks the graph before anything runs:

- **Missing registrations** are reported at build time, not at first request.
- **Dependency cycles** are reported with the cycle named.
- **`@ConfigValue` keys** are checked against `flight.yaml`.
- **Existential bridges** are synthesized: a protocol with exactly one
  conformer is resolvable as `any Protocol` without hand-written glue.

A component that is registered by hand rather than scanned is acknowledged
with a comment, so the check does not have to choose between false positives
and silence:

```swift
// flight:hand-registered
@Inject var external: SomethingFromAnotherLibrary
```

### Types their own module registers

The scan covers your target *and every Flight-based package it links*. That is
usually what you want, but some types must not be registered just because a
package is linked: whether they should exist at all is a runtime question —
a configuration gate, or an optional subsystem the app may not have included.

Mark those with `flight:module-registered`, above the declaration:

```swift
// flight:module-registered — FlightSecurityModule registers this.
@Middleware
public struct Authentication: Sendable {
    @Inject var validator: (any TokenValidator)
}
```

The type is still scanned — its dependencies are still checked, and `@Inject`
of it still resolves without a warning — but the composition root does not
build it as a graph node of its own, and it is never chosen as an existential
bridge conformer. Its module provides it instead. The generated file names
every type it skipped for this reason, so nothing disappears silently.

Why it matters: a component is built eagerly, at composition. `Authentication`
injects `(any TokenValidator)`, which only a security module provides, so
without the marker any app that merely *linked* the security package could not
compose and never booted.

> The plugin is a `BuildToolPlugin` and runs under SwiftPM. Xcode projects do
> not run it, so an Xcode-only target needs its registrations written by hand.

## Modules

A module declares what it needs and *holds* what it provides, built in its
initializer:

```swift
struct DataModule: FlightModule {
    static let dependencies: [any FlightModule.Type] = [ConfigModule.self]

    let dataSource: DataSource
    init(configuration: Configuration) throws {
        self.dataSource = PostgresDataSource(configuration: configuration)
    }
}
```

The composition root builds each module in dependency order and wires what one
provides into whatever injects it, by type.

Order is resolved from the declared dependencies and is deterministic: the
same module set always produces the same order. A cycle is a startup error
naming the modules involved.

### Two providers of one type

Wiring by type has one thing it cannot decide for you. If two modules each
provide a `ConnectionPool`, an unqualified `@Inject var pool: ConnectionPool`
does not say which one it meant, and the build stops rather than picking.

This is a shape worth supporting — a primary pool and a replica, a real
client and a recording one — so the fix is to name the default rather than to
give the types different names. In the module that lists both providers:

```swift
struct AppModule: FlightModule {
    static let includedModules: [any FlightModule.Type] = [
        PrimaryPoolModule.self, ReplicaPoolModule.self,
    ]
    // What an unqualified @Inject of a doubly-provided type resolves to.
    static var defaultProviders: [any FlightModule.Type] { [PrimaryPoolModule.self] }
}
```

Everything that asks for a `ConnectionPool` by type now gets the primary one.
Where you want the other, name it at the injection site:

```swift
@Component
struct ReportBuilder {
    @Inject var pool: ConnectionPool                             // primary
    @Inject(from: ReplicaPoolModule.self) var replica: ConnectionPool
}
```

`@Inject(from:)` is a compile-time choice like every other part of the graph:
it names a module type, it is resolved by the generator, and it costs nothing
at runtime. It is only needed for the ambiguous types — the rest of the
application keeps injecting by type alone.

You do not have to know in advance which types are ambiguous. The build tells
you when a second provider appears, and the diagnostic contains both lines
above with your own module and type names already substituted in.

## Configuration as a typed value

`@ConfigValue` binds one key to one property. A group of related settings is a
type instead:

```swift
@Settings("auth")
struct AuthSettings {
    var issuer: String = "myapp"
    @Secret var signingKey: String           // required — no default
    var tokenLifetime: Duration = .hours(12) // "12h", "500ms", ...

    func validate() throws {
        guard signingKey.count >= 32 else { throw AuthError.signingKeyTooShort }
    }
}
```

Keys are derived from the namespace and the property name, kebab-cased:
`auth.issuer`, `auth.signing-key`, `auth.token-lifetime`. A property with a
default reads as "use it only if the key is absent"; a property without one is
**required**, and a required key missing from `flight.yaml` is a build error,
not a first-request surprise. An explicit `@ConfigValue("other.key")` on a
property overrides the derived name.

A `validate()` taking no parameters runs once, right after construction, at
composition — the place a bad value should fail. The type composes like
anything else: `@Inject var settings: AuthSettings` wherever you need it.

Two constraints the macro enforces rather than letting you discover: a property
may not be `Optional` (a key that may or may not exist has no single answer for
"what did we configure" — give it a concrete default), and a property with a
default must be `var`, since the generated initializer overrides that default
when configuration supplies a value.

`@Secret` marks a property whose value must not leak into logs. When any
property carries it, the generated `description` renders that field as
`<REDACTED>`, so a stray `logger.info("\(settings)")` or a crash report does
not print it. It governs the settings object's own textual representation —
marking the underlying key secret in Flight Config's diagnostic dump is a
separate mechanism, `Configuration.load(secrets:)`.

## Transactions

Transactions belong to your data layer, not to Core. With Hangar:

```swift
try await repo.transaction { tx in
    try await tx.debit(from, amount)
    try await tx.credit(to, amount)   // a throw here rolls back the debit
}
```

Returning commits; throwing rolls back. Nested `transaction { }` calls become
savepoints. The closure receives a `Repo` bound to the transaction's
connection — use it, not the outer repo, or the work runs outside the
transaction. Isolation level and retry-on-serialization-failure are arguments:
`transaction(isolation: .serializable, retryingOnSerializationFailure: 3)`.

Core previously offered a `@Transactional` macro that wrapped a method body
against an ambient coordinator. It was removed: the boundary it created was
invisible at the call site, its nesting semantics had to *guess* whether a
transaction was already open (a guess that could silently turn a rollback into
a durable commit), and it could express neither isolation levels nor retry.
An explicit closure makes the boundary and its extent visible in the code that
opens it.

## Testing

`Flight.assemble` composes the modules and returns their services, without
running anything:

```swift
let app = try Flight.assemble(configuration: config, modules: [appModule])
```

A component takes what it needs as `@Inject` parameters, so swapping in a test
double is just constructing it with one — no container to override:

```swift
let service = UserService(repository: InMemoryUsers())
```

That is the whole of it: a test builds the type under test with fakes passed
in, and never reaches for framework wiring to do it.

## Documentation

```bash
FLIGHT_BUILD_DOCS=1 swift package generate-documentation --target FlightCore
```

## License

MIT. See [LICENSE](LICENSE).
