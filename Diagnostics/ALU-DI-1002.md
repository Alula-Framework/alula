# ALU-DI-1002: Several modules provide the same type

**Severity:** error

## Meaning

Two or more modules provide a value of the same type, and something asks
for that type without saying which one it means.

## Why Alula rejects it

Composition never guesses. Picking one provider silently — the first, the
last — is how a service ends up talking to the wrong database. When an
application acquires a second provider, the build is the one place that
knows, so it stops and asks.

## Common causes

- A second instance of a module, such as another `PostgresDataModule` for
  an analytics database.
- Two authentication modules that both provide a token validator.

## Fixes

1. Say which provider an unqualified `@Inject` means, in the module that
   lists them:
   `static var defaultProviders: [any AlulaModule.Type] { [PrimaryModule.self] }`
2. Name the other one where you want it: `@Inject(from: AnalyticsModule.self)`.
3. Remove the provider you did not mean to include.

## Example

```swift
@Inject var pool: PostgresDataSource                          // ambiguous
@Inject(from: AnalyticsDataModule.self) var pool: PostgresDataSource  // chosen
```

## Related

ALU-DI-1001, ALU-DI-1005, ALU-DI-1007.
