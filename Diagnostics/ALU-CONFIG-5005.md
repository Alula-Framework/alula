# ALU-CONFIG-5005: A configuration prefix that cannot name environment variables

**Severity:** error

## Meaning

`Configuration.load(prefix:)` is given a prefix with characters other than
lowercase ASCII letters, digits and underscores, or one that does not start
with a letter.

## Why Alula rejects it

The prefix names the base file (`<prefix>.yaml`) and, uppercased, prefixes
every environment variable that overrides it: `MYAPP_SERVER_PORT`. A prefix
like `My-App` gives `MY-APP_SERVER_PORT`, which most shells cannot set.
`Configuration.load` traps on it at startup; the build says so first.

## Fixes

1. Use lowercase letters, digits and underscores: `Configuration.load(prefix: "my_app")`.

## Related

ALU-CONFIG-5006.
