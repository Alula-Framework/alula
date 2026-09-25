# ALU-DI-1003: Components depend on each other in a cycle

**Severity:** error

## Meaning

Following `@Inject` properties from one component leads back to it:
`UserService → AuditService → UserService`.

## Why Alula rejects it

Components are constructed once, in dependency order. A cycle has no first
member, so no order can construct them.

## Common causes

- Two services that each call the other.
- A shared responsibility — auditing, notification — injected into the
  very service it depends on.

## Fixes

1. Extract the shared responsibility into a third component both depend on.
2. Inject a narrower dependency: a closure, a protocol with only the method
   needed, or a value the module provides.
3. Pass the value at call time instead of holding it.

## Example

```text
UserService → AuditService → UserService
```

Extract `AuditLog` from `UserService`, and inject `AuditLog` into both.

## Related

ALU-LIFE-8001 (modules in a cycle).
