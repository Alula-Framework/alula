# Flight Actuator

A lightweight, no-frills introspection surface for a running Flight app —
what components are registered, which modules are healthy, basic runtime facts —
served over HTTP. This README covers usage and records the choices the
implementation had to make.

## Adding this module

| | |
|---|---|
| **Trait** | `Web` |
| **Products** | `FlightActuator` |
| **Module** | `ActuatorModule.self` |

```swift
// Package.swift
dependencies: [
    .package(
        url: "https://github.com/Flight-Framework/flight.git",
        from: "0.31.0", traits: ["Web"]),
],
targets: [
    .executableTarget(
        name: "App",
        dependencies: [
            .product(name: "FlightCore", package: "flight"),
            .product(name: "FlightWeb", package: "flight"),
            .product(name: "FlightTransport", package: "flight"),
            .product(name: "FlightActuator", package: "flight"),
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
import FlightActuator
import FlightCore
import FlightTransport
import FlightWeb

@main
struct Main {
    static func main() async {
        await Flight.run(
            configuration: try Configuration.load(),
            modules: [
                FlightWebModule<FlightTransport>.self,
                ActuatorModule.self,
                AppModule.self,
            ],
            composedBy: flightComposeModules)
    }
}
```

The actuator serves HTTP endpoints, so it runs alongside a web module and a
transport.

The `modules:` list names roots, not an order — the build resolves the
dependency DAG. A module you write can declare framework modules in its own
`dependencies`, in which case listing yours is enough.

## Usage

Actuator is an ordinary `FlightModule` — registered like everything else,
with no special access to Core or Web:

```swift
import FlightActuator

await Flight.run(
    configuration: try Configuration.load(),
    modules: [
        FlightWebModule<FlightTransport>.self,
        ActuatorModule.self,
        AppModule.self,
    ],
    composedBy: flightComposeModules
)
```

`GET /actuator` then serves the dashboard — server-rendered HTML by
default, or the same data as JSON:

```yaml
# flight.yaml
actuator:
  format: ssr   # or "json"
```

(or `FLIGHT_ACTUATOR_FORMAT=json` via the env-var config layer). The key is
read once at bootstrap. An absent key means SSR; a present-but-malformed
value fails bootstrap loudly, naming the key and value — never a silent
fallback (Flight Config).

## Access gating

Three levels, decided at bootstrap and never re-read:

Set with `FLIGHT_ACTUATOR_EXPOSURE`, or derived from `FLIGHT_ENV` when that
is unset — **not** a `flight.yaml` key, unlike `actuator.format` above. The
reason is below; writing `actuator: exposure:` into `flight.yaml` does
nothing, silently.

| exposure | Routes registered |
| --- | --- |
| `disabled` | none |
| `health_only` | all three health probes — `/actuator/health`, `/actuator/health/live`, `/actuator/health/ready`. No topology in any of them. |
| `full` | the three probes **and** the dashboard: module list, every component's type name, failure messages |

The probes are published wherever the actuator is enabled at all, because an
orchestrator needs them in production and an all-or-nothing gate is why
production used to have none. Only the *dashboard* is gated further.

`full` is the default in `dev`, `development`, `test` and `local` — when
`FLIGHT_ENV` actually *says* so. **An unset `FLIGHT_ENV` is `health_only`**,
not `dev`: everywhere else an unset variable means development
([config](config.md)), but the question here is whether to publish an
unauthenticated description of your topology, and "nobody set the variable"
is not an answer worth acting on. Set `FLIGHT_ENV=dev` (or
`FLIGHT_ACTUATOR_EXPOSURE=full`) to get the dashboard.
**Everywhere else the default is `health_only`** — an orchestrator needs a
probe in production, and an all-or-nothing gate left production with none.

An unrecognised value fails bootstrap naming the key rather than falling back,
for the reason given under [What gets published, and where](#what-gets-published-and-where): this decides
whether an endpoint disclosing your topology exists.

`FLIGHT_ACTUATOR_EXPOSURE` overrides it. That is an environment variable
rather than a config key because it gates whether an endpoint that discloses
your topology exists at all — a deployment decision Actuator reads from the raw
environment, its one sanctioned exception to reading configuration instead.

The dashboard is open unless configured otherwise, so `full` anywhere
reachable wants `actuator.dashboard-pipelines` (below). `health_only` is safe
to expose: it answers `200`/`UP` or `503` and discloses nothing else.

For tests and embedders, `ActuatorModule(environment:)` bypasses the
`FLIGHT_ENV` read — construct it directly with the environment you want.

## JSON contract

The JSON rendering is a public contract for hand-rolled front-ends. Shape
(stable, sorted keys; absent optionals are *omitted*, not `null`-encoded):

```json
{
  "environment": "dev",
  "modules": [
    {"module": "AppModule", "health": "running"},
    {"module": "JobsModule", "health": "failed", "error": "…"}
  ],
  "components": [
    {"type": "App.UserService", "stereotype": "service",
     "sourceModule": "AppModule"}
  ]
}
```

- `health`: `"notStarted" | "running" | "failed"` (`error` present only for
  `"failed"`)
- `stereotype`: `"component" | "service" | "repository" | "controller" |
  "settings" | "middleware"` — all six of Core's `Stereotype` cases; a
  front-end validating against this contract should accept the lot

`scope` and `qualifier` were part of this contract until 0.20.0, which removed
both from `ComponentDescriptor` — singleton was the only scope, and the
qualifier was never wired. A front-end reading either field must stop; the
dashboard's Scope and Qualifier columns went at the same time.

The encoding is hand-written rather than retroactive `Codable` on Core's
types, so Core can evolve its introspection structs without silently
changing this wire format.

## Design deltas

Recorded here the same way sibling packages record theirs:

1. **`ActuatorController` is a plain struct, hand-registered — not
   `@Controller`.** An early revision used `@Controller` and broke the
   moment a real app depended on this package: Flight Core's registration
   plugin scans *every* recursive source-module dependency that sits atop
   FlightCore — right for an app-owned library target, wrong for a starter
   package with its own `FlightModule`. A downstream app's generated
   composition root would try to build `ActuatorController` as one of its own
   graph nodes — bypassing the exposure gate entirely (whole point) and
   colliding with what `ActuatorModule` already does. Every sibling starter
   (`flight-web`, `flight-pubsub`, `flight-channels`, `flight-data-postgres`)
   avoids this the same way: none of them put `@Component`/`@Controller` on
   their own infrastructure. `ActuatorModule` builds the controller and serves
   it through route values (`RouteRegistration`, the escape hatch `@GetRoute`
   sits beside).
2. **The controller is handed its data, not a container.** A consequence
   of (1): `ActuatorController` holds its inputs as plain stored properties —
   the scanned component list from the composition root, and a
   `ModuleHealthRegistry` for module health — set when `ActuatorModule` builds
   it. Nothing is `@Inject`ed and nothing is resolved at request time, so the
   guarded self-registration (and its duplicate-registration-avoidance dance)
   is gone with the container.
3. **The gate's environment is a qualified component.** The dashboard reports
   the same environment the registration gate ran against, injected as
   `FlightEnvironment` with qualifier `"flight.actuator"`, rather than
   re-reading `FLIGHT_ENV` per request. The two can otherwise disagree
   under the explicit-environment initializer.
4. **`ModuleHealth.isFailed` (and friends) live here.** The design's own
   test sketch uses `health.isFailed`; Core keeps `ModuleHealth` minimal,
   so the presentation predicates and stable labels ship in this package
   as extensions.
5. **Config is read at composition, not per request.** `actuator.format` is
   read once when `ActuatorModule` is built — the composition root hands it the
   `Configuration` — before any request, matching what `@ConfigValue` would
   have given. Reached via `Configuration.getIfPresent(_:as:) ?? .ssr`, not
   `get(_:default:)`: the latter is non-throwing and `fatalError`s on a
   malformed *present* value; `getIfPresent` throws instead, so a malformed
   value fails composition loudly rather than trapping the process — the same
   distinction the `@ConfigValue` macro's own `default:` expansion relies on.

`ActuatorController`'s registration is explicitly tagged
`stereotype: .controller`, so it groups under *Controllers* on its own
dashboard, same as it would have under the macro — no dependency on
whatever `@Controller`'s own stereotype-tagging does upstream.

## Testing

No HTTP round-trip is required to test the data assembly —
`ActuatorSnapshot` is a plain `Sendable` struct assembled from a
`ModuleHealthRegistry`'s statuses and the component list the build scanned. The suite covers
environment gating, snapshot assembly (including a module whose service
fails through the real `assemble` health-tracking path), both renderings,
HTML escaping of hostile registration metadata, and config resolution:

```
swift test
```

## What gets published, and where

| exposure | `/actuator/health` | `…/health/live` | `…/health/ready` | `/actuator` |
|---|---|---|---|---|
| `disabled` | — | — | — | — |
| `health_only` | yes | yes | yes | — |
| `full` | yes | yes | yes | yes |

The default is `full` in `dev`, `development`, `test`, and `local`, and
`health_only` everywhere else — **including any environment name this
package does not recognize**.

That last clause is the point. The gate used to be `environment != .prod`,
which fails open twice over: an unset `FLIGHT_ENV` resolves to `dev`, and
`production`, `PROD`, `prd`, and `live` are all not-`.prod` too. Each of
them published the dashboard — the module list, every registered
component's fully-qualified type name, and failure messages —
unauthenticated, on a deployment whose operator believed otherwise.
Getting the environment name wrong now costs you a dashboard instead of
leaking one.

The allowlist closed the misspelled-name half of that and, for a while,
left the other half exactly as it was: an unset `FLIGHT_ENV` still resolved
to `dev`, `dev` was still on the allowlist, and a production deployment that
never set the variable still served the whole dashboard. **A default is not
a declaration.** Saying nothing now gets `health_only`; a development machine
that wants the dashboard says so, with `FLIGHT_ENV=dev` or the override
below.

### The health probes

Three routes, published wherever the actuator is enabled at all, because an
orchestrator needs probes in production and the old all-or-nothing gate left
production with none:

| | |
|---|---|
| `GET /actuator/health` | The strict aggregate: `UP` only when every module is running. |
| `GET /actuator/health/live` | Is the process wedged? A module that has not started yet does **not** count — a slow-starting pod answering `DOWN` here gets killed and restarted into the same slow start, forever. Only a module whose service threw counts, because that is what a restart can clear. |
| `GET /actuator/health/ready` | Can it serve traffic? Strict: still starting, or failed, means no. |

Each answers `200`/`UP` or `503`/`DOWN` with counts and nothing else — no
component list, no type names, no failure text. They are safe to publish
unauthenticated precisely because of what they leave out.

Health inputs are Core's module lifecycle by default: a module is `running`
once it is composed and `failed` if its `Service.run()` throws. A module that
is up but cannot reach its database says so on the `ModuleHealthRegistry` the
composition root provides:

```swift
health.reportHealth(.failed(error), forModule: "DataModule")
```

on whatever cadence suits it — a background check, a connection-pool
callback. Nothing here polls, and no check runs on the request path, which is
what removes the hung-check-and-timeout class of bug entirely: a probe is a
lock-protected read of state something else already established.

To opt a non-development environment into the dashboard:

```sh
FLIGHT_ACTUATOR_EXPOSURE=full
```

That is an environment variable rather than a `flight.yaml` key because it
decides whether a topology-disclosing route exists *at all* — a deployment
question Actuator answers from the raw environment, its one sanctioned
exception to a module reading configuration instead. It is the env-var spelling
of `actuator.exposure` under Flight Config's own convention. An unrecognized
value stops startup rather than quietly choosing for you.

**Put authentication in front of it.** Two settings do it:

```yaml
actuator:
  dashboard-pipelines: authenticated   # lanes the /actuator route runs through
  dashboard-roles: operator, sre       # any one of these; optional
```

`dashboard-pipelines` names lanes exactly as a route's `pipelines:` does;
`authenticated` is the lane `FlightSecurityModule` declares, so a signed-in
principal is required before the dashboard renders. `dashboard-roles` runs
the same check as a `roles:` route — 401 with no credential, 403 with the
wrong one. Roles need a lane that establishes identity; on one that doesn't,
every caller is anonymous and gets a 401 — locked rather than open. A key
present but naming nothing fails startup rather than reading as "no
restriction".

The health routes are never gated. An orchestrator's probe has no
credential to present, and a probe that answers 401 restarts a healthy pod.
Startup still warns about `full` outside a development environment unless
the dashboard requires someone — a role, or the `authenticated` lane.

One thing worth knowing before you turn it on anywhere real: a failed
module's error text is served verbatim, and connection errors routinely
interpolate the URL they failed on — which can carry credentials. No
scrubbing is attempted, because guessing at which substrings of an arbitrary
error are secret is the kind of half-measure that reads as a guarantee.
Wherever `full` is on, treat those strings as disclosed.

## Non-goals

No live-updating dashboard, no historical/metrics data, and no per-component
instance inspection. No metrics endpoint of any kind: metrics want a
dedicated library with its own cardinality and retention story, and half of
one here would be worse than none. The README used to advertise them anyway;
it no longer does.

