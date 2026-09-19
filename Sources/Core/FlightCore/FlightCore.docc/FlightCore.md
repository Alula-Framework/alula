# ``FlightCore``

Dependency injection and application bootstrap, wired at compile time.

## Overview

A dependency container usually trades one problem for another: you stop
writing constructor plumbing, and you start finding out at 3am that a
component was never registered.

Flight wires dependencies with a build plugin that reads your sources, so a
missing dependency or a dependency cycle is a build error rather than a
runtime surprise — and there is no container to resolve against once the
process is running:

```swift
@Service
final class UserService: Sendable {
    @Inject let repository: any UserRepository
    @ConfigValue("features.signup_enabled", default: true) let signupEnabled: Bool
}
```

```swift
await Flight.run(
    configuration: try Configuration.load(),
    modules: [WebModule.self, DataModule.self],
    composedBy: flightComposeModules
)
```

## Composition

Modules are values. A ``FlightModule`` holds what it provides — its stored
properties — and takes what it needs — its initializer parameters. A generated
*composition root* builds every module and component **once**, in dependency
order, wiring them by type. There is no registration step and no lookup.

Construction is **eager**, at composition: a `@ConfigValue` that fails to read,
or an initializer that throws, fails startup — where someone is watching —
rather than the first request unlucky enough to touch it. Afterwards every
component is a shared singleton, reached directly, so there is nothing to
resolve per request.

## Components should be Sendable

A singleton is shared across every task in the process, so in practice it must
be `Sendable`: a shared, mutable, non-`Sendable` singleton handed to two tasks
is a data race with no diagnostic at all.

Nothing checks this for you. `@Service` adds an initializer; it adds no
conformance and no constraint, and a mutable `final class` component compiles
cleanly — the constraint left with the container in 0.17.0. Declaring
`Sendable` is what turns the requirement into something the compiler can see.

Per-request mutable state does not belong on a singleton. It rides the request
context as a typed value — one copy per request, never shared between them.

## Topics

### Bootstrapping

- ``Flight``
- ``AssembledApplication``
- ``AssembledService``
- ``ServiceShutdownPhase``
- ``ServiceCompletionPolicy``
- ``BootstrapError``

### Macros

- ``Component()``
- ``Service()``
- ``Repository()``
- ``Inject(from:)``
- ``ConfigValue(_:)``
- ``ConfigValue(_:default:)``
- ``Settings(_:)``
- ``Secret()``

### Modules

- ``FlightModule``
- ``ModuleHealth``
- ``ModuleStatus``
- ``ModuleHealthRegistry``

### Resolution

- ``ResolutionError``

### Introspection

- ``ComponentDescriptor``
- ``Stereotype``

### Guides

- <doc:Lifetimes>
- <doc:CompileTimeWiring>
