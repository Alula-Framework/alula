# ALU-CONFIG-5012: Configuration written for Flight, before the rename

**Severity:** error

## Meaning

The environment or the configuration directory still uses the framework's
old name: `FLIGHT_ENV` without `ALULA_ENV`, or a `flight.yaml` /
`flight-<env>.yaml` file.

## Why Alula rejects it

Reading on would be quietly wrong. An unset `ALULA_ENV` means `dev`, so a
production deployment still setting `FLIGHT_ENV=prod` would start with the dev
overlay and dev actuator exposure.

## Fixes

1. Rename each: `FLIGHT_` to `ALULA_`, `flight` to `alula`.
2. Or keep the old names deliberately: `Configuration.load(prefix: ConfigPrefix("flight"))`.

## Related

ALU-CONFIG-5010.
