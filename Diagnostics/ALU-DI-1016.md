# ALU-DI-1016: An @Inject or @ConfigValue property has no written type

**Severity:** error

## Meaning

An `@Inject` or `@ConfigValue` property is declared without a type
annotation, e.g. `@Inject var mailer = SMTPMailer()`.

## Why Alula rejects it

Injection resolves by the static type as written. Without an annotation
there is nothing for the generated initializer to ask for.

## Fixes

1. Write the type: `@Inject var mailer: Mailer`.
2. If the property is not meant to be injected, remove the attribute.

## Example

```swift
@Inject var mailer: Mailer
@ConfigValue("server.port") var port: Int
```

## Related

ALU-DI-1011, ALU-DI-1019.
