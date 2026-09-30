# ``AlulaCore``

Dependency injection and application bootstrap, wired at compile time.

## Overview

A dependency container usually trades one problem for another: you stop
writing constructor plumbing, and you start finding out at 3am that a
component was never registered.

Alula wires dependencies with a build plugin that reads your sources, so a
missing dependency or a dependency cycle is a build error rather than a
runtime surprise — and there is no container to resolve against once the
process is running:

```swift
@Service
final class UserService: Sendable {
    @Inject let repository: any UserRepository
    @ConfigValue("features.signup-enabled", default: true) let signupEnabled: Bool
}
```

```swift
await Alula.run(
    configuration: try Configuration.load(),
    modules: [WebModule.self, DataModule.self],
    composedBy: alulaComposeModules
)
```

## Composition

Modules are values. A ``AlulaModule`` holds what it provides — its stored
properties — and takes what it needs — its initializer parameters. A generated
*composition root* builds every module and component **once**, in dependency
order, wiring them by type. There is no registration step and no lookup.

Construction is **eager**, at composition: a `@ConfigValue` that fails to read,
or an initializer that throws, fails startup — where someone is watching —
rather than the first request unlucky enough to touch it. Afterwards every
component is a shared singleton, reached directly, so there is nothing to
resolve per request.

## Components are Sendable

A singleton is shared across every task in the process, so it must be
`Sendable`: a shared, mutable, non-`Sendable` singleton handed to two tasks is
a data race.

`@Service` adds an initializer, not a conformance, so the build checks it
instead. A struct of `Sendable` values is `Sendable` without saying so; a
class component that does not declare `Sendable` is a build error at the class
(ALU-DI-1020), and once it declares it the compiler checks its stored
properties. A class isolated to a global actor counts as `Sendable` already,
and a controller, built per request rather than held, is not checked.

`@Service` is only the "build this and share it" annotation. It has nothing to
do with a module's lifecycle service — ``AlulaModule/service``, a
ServiceLifecycle `Service` with a `run()` — and annotating a type `@Service`
starts nothing.

Per-request mutable state does not belong on a singleton. It rides the request
context as a typed value — one copy per request, never shared between them.

## Topics

### Bootstrapping

- ``Alula``
- ``Configuration``
- ``AssembledApplication``
- ``AssembledService``
- ``ServiceShutdownPhase``
- ``ServiceCompletionPolicy``

### Macros

- ``Service()``
- ``Repository()``
- ``Inject(from:)``
- ``ConfigValue(_:)``
- ``ConfigValue(_:default:)``
- ``Settings(_:)``
- ``Secret()``

### Modules

- ``AlulaModule``
- ``ModuleHealth``
- ``ModuleStatus``
- ``ModuleHealthRegistry``

### Resolution

- ``ResolutionError``

### Lifecycle

- ``LifecycleHook``
- ``LifecycleSettings``
- ``CommandRegistration``
- ``CommandContext``
- ``ShutdownDeadline``
- ``Deadline``
- ``withAlulaTimeout(_:throwing:_:)``
- ``FirstAnswer``

### Health

- ``HealthCheck``
- ``HealthCheckResult``

### Startup failures

- ``RejectedInput``
- ``TemporarilyUnavailable``
- ``AdapterCandidate``
- ``UnloadedAdapterError``

### Logging

- ``LoggingSettings``
- ``JSONLogHandler``

### Introspection

- ``ComponentDescriptor``
- ``Stereotype``

### Guides

- <doc:Lifetimes>
- <doc:CompileTimeWiring>
- <doc:Diagnostics>
