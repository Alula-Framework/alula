# ALU-CONFIG-5004: A configuration key the base file does not define

**Severity:** error

## Meaning

A `@ConfigValue` key, or a `@Settings` property's key, has no default and is
not in the application's base configuration file (`alula.yaml`, or
`<prefix>.yaml`).

The same code is printed at startup when a key is set in no source at all — the build checks only the base file, and a key can depend on the environment.

## Why Alula rejects it

A key with no value and no default fails the application at startup. The
base file is the one layer every environment loads, so a key missing from it
is missing everywhere unless something else happens to supply it — and the
build can check that now rather than a deploy finding out.

## Common causes

- A new `@ConfigValue` whose key was not added to `alula.yaml`.
- A typo in the key, or in the YAML nesting.

## Fixes

1. Add the key to the base file. For a value the environment supplies, a placeholder is enough: `password: ${MAIL_PASSWORD}`.
2. Or give it a default: `@ConfigValue("mail.port", default: 25)`, or a default value on the `@Settings` property.

## Example

```swift
# alula.yaml
mail:
  host: smtp.example.com
  from: ${MAIL_FROM}
```

## Related

ALU-CONFIG-5001, ALU-CONFIG-5006.
