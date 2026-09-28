# ALU-DI-1020: A class component that is not Sendable

**Severity:** error

## Meaning

A `@Service`, `@Repository` or other component is a class that
does not declare `Sendable`.

## Why Alula rejects it

A component is built once and shared: every request and every task reads the
same instance, through the application graph that holds it. The graph can be
shared across tasks only if everything in it is `Sendable`, and one class that
is not makes the whole graph not `Sendable`.

Without this check the compiler still refuses the build, but not here. It
reports it wherever generated code captures the graph —
`capture of 'graph' with non-Sendable type 'AlulaGraph' in a '@Sendable'
closure`, in `AlulaRegistration.generated.swift` — naming none of your types.

A struct of `Sendable` values is `Sendable` without saying so. A class has to
declare it, and then the compiler checks it: a stored `var`, or a property of a
type that is not `Sendable`, is an error on the class itself.

## Common causes

- `@Service final class Something { … }` written without `: Sendable`.
- A class that was a struct, converted to hold a reference.

## Fixes

1. Declare the conformance and make stored properties `let`:
   `final class Something: Sendable { @Inject let repository: any Repository }`.
2. Or make it a struct — usually the simpler answer when nothing depends on
   its identity.
3. Mutable shared state belongs behind a lock or an actor the class holds as a
   `let`: `let cache = Mutex<[Key: Value]>([:])`.

A class isolated to a global actor (`@MainActor`) is `Sendable` already and is
not reported. Controllers are built per request, not held by the graph, and
are not reported either.

## Related

ALU-DI-1018.
