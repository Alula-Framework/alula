# ALU-CONFIG-5003: A @Settings property Alula cannot bind

**Severity:** error

## Meaning

A property of a `@Settings` type (or a `@Secret`) is declared in a way
binding cannot handle:

- `@Inject` inside settings;
- no written type;
- an optional type;
- a `let` with a default value;
- `@Secret` on something that is not a stored property.

## Why Alula rejects it

Settings bind configuration once, at bootstrap, by static type. A
dependency does not belong there; an untyped property has nothing to bind
to; an optional would leave "what did we configure" with no single answer;
and a `let` default could never be overridden by configuration.

## Fixes

1. Move dependencies to a `@Service` or `@Component`.
2. Write the type.
3. Replace the optional with a concrete default.
4. Use `var` for a property with a default.

## Example

```swift
@Settings("mail")
struct MailSettings {
    var host: String = "localhost"
    @Secret var password: String
}
```

## Related

ALU-CONFIG-5002.
