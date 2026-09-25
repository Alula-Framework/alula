# ALU-DI-1015: Two @Inject properties of one type

**Severity:** error

## Meaning

A `@Component`, `@Controller` or `@Middleware` type has two `@Inject`
properties of the same type, and nothing tells them apart.

## Why Alula rejects it

Composition wires by type. Two properties of one type would both receive
the same value — or, if you meant two different providers, one of them
would silently get the wrong one.

## Common causes

- Two data sources of one type, one meant for a replica.
- A copied property that was meant to be renamed or retyped.

## Fixes

1. If you meant two providers, name one of them: `@Inject(from: ReplicaModule.self)`.
2. Give the values distinct types — a small wrapper struct is enough.
3. If both name the same provider, delete one; they would hold the same value.

## Example

```swift
@Inject var primary: PostgresDataSource
@Inject(from: ReplicaDataModule.self) var replica: PostgresDataSource
```

## Related

ALU-DI-1002, ALU-DI-1007.
