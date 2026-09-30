# Compile-time wiring

What the build plugin checks, and what to do when it complains.

## Overview

A build plugin scans your sources, generates the wiring, and
checks the graph before anything runs. The point is that the failures a DI
container is famous for — a component nobody registered, a cycle nobody
noticed — become build errors.

```swift
.target(
    name: "MyApp",
    dependencies: [.product(name: "AlulaCore", package: "alula")],
    plugins: [.plugin(name: "AlulaRegistrationPlugin", package: "alula")]
)
```

## What it checks

Every problem is reported in the compiler's format with a stable code —
`error: [ALU-DI-1001] no module in this application provides …` — so an IDE attaches it to your
line, and each code has a page saying why it is refused and how to fix it.
<doc:Diagnostics> has the families and where the pages are.

**Missing registrations.** An `@Inject` property whose type is not a
scanned component or a value an included module provides is a build error
naming the type (a warning in a library target, which includes no modules).

**Dependency cycles.** Reported with the cycle spelled out, so you can see
which edge to break.

**`@ConfigValue` keys.** Checked against `alula.yaml`. A typo in a
configuration key is a build error rather than a startup failure.

**Declaration shapes.** `@Service` and `@Repository` — and
`@Controller` and `@Middleware` — go on a struct or a `final class`. A class
without `final` is a build error (ALU-DI-1018, ALU-WEB-2003) with a fix-it that
adds it.

**Existential bridges.** A protocol with exactly one conformer is resolvable
as `any Protocol` with no hand-written glue:

```swift
protocol UserRepository: Sendable {}

@Repository
final class PostgresUserRepository: UserRepository, Sendable {}

@Service
final class UserService: Sendable {
    @Inject let repository: any UserRepository   // wired automatically
}
```

Two conformers is genuine ambiguity, and the plugin declines to guess. Inject
the concrete type, or have a module provide `any UserRepository` — see
below.

There is no qualifier to add. Both spellings of one were removed in 0.20.0:
the type-level `@Service(qualifier:)`, which expanded to nothing, and the
property-level `@Inject("name")`, which the wiring never read — two `@Inject`
properties of one type silently received the same instance, and are now a
build error instead.

``Inject(from:)`` is not one of them reinstated. It names the *module* that
provides a value, which answers "which of two modules" — a different question
from "which of two conformers", where there is no module involved and the
concrete type is still the answer.

## Dependencies a module provides

Not everything is a scanned component. Most of an application's dependencies
are values a module holds — `PostgresDataModule`'s `PostgresDataSource`, a
security module's `any TokenValidator` — and the scan sees those modules too.
Write the injection and nothing else:

```swift
@Inject var pool: PostgresDataSource
```

In an application the composer wires it from whichever included module
provides it, and a type no included module provides is a build error
(ALU-DI-1001). An existential a module provides is taken from the module even
when a scanned component also conforms: the module's value is the deliberate
choice. In a library, which includes nothing, any module the scan saw counts,
and a type none provides is a warning (ALU-DI-1009).

Earlier releases asked for a `// alula:hand-registered` comment on such a
property. The build now infers what it said, so it is an ordinary comment and
can be deleted.

## Limits worth knowing

**Nested types are not scanned.** A `@Service` declared inside another type
is skipped silently, so nothing that depends on it will be wired. Declare
components at file scope.

**Matching is by base name.** The checker and the composer both key on the
last dotted component of a type name, so two modules each providing a
`UserService` look like one type to either of them, even though Swift
considers them distinct. This is not only a matter of diagnostic quality:
composition sees two providers of one type and stops, because an unqualified
`@Inject` cannot say which of them it meant.

Two providers of one type is a legitimate shape — a primary pool and a
replica, say — so the build asks you to name the default rather than refusing
it outright. ``AlulaModule/defaultProviders`` declares which one an
unqualified `@Inject` resolves to, and ``Inject(from:)`` names the other
wherever you want it instead:

```swift
extension AppModule {
    static var defaultProviders: [any AlulaModule.Type] { [PrimaryPoolModule.self] }
}

@Inject var pool: ConnectionPool                        // primary
@Inject(from: ReplicaPoolModule.self) var replica: ConnectionPool
```

The diagnostic spells out both lines with your own module names in them.

**Xcode does not run it.** The plugin is a `BuildToolPlugin`, which SwiftPM
runs and Xcode projects do not. An Xcode-only target needs its wiring
written by hand.

## When the plugin is wrong

It is a checker, not an oracle. If it reports a missing registration for
something you provide as a value, the answer is a module that holds that value
as a stored property and is included in the application — the scan sees
included modules and wires from them — not disabling the plugin. If it reports a cycle you believe is not one, the
cycle is usually real and mediated by a type you forgot participates.
