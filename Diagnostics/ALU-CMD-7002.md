# ALU-CMD-7002: No command by that name

**Severity:** error

## Meaning

The application was started with an argument that names no command, such as
`swift run App sync-inventroy`. The report lists the commands there are.

## Why Alula rejects it

Any first argument that is not a flag is read as a command name, so a typo
cannot quietly start the server instead.

## Common causes

- A typo in the name.
- The module that declares the command is not in `modules:`.

## Fixes

1. Use a name from the listing — `swift run App commands` prints it.
2. Add the module that declares the command to `modules:`.
3. To serve, pass no argument, or `serve`.

## Related

ALU-CMD-7001.
