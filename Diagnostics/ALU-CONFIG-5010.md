# ALU-CONFIG-5010: No base configuration file at startup

**Severity:** error

## Meaning

`Configuration.load` found no base file (`alula.yaml`, or `<prefix>.yaml`)
where it looked: relative to the process's working directory.

## Why Alula rejects it

The base file is the layer every environment loads; only the
`<prefix>-<env>.yaml` overlays are optional. Starting without it would run on
whatever the environment happens to supply.

## Common causes

- A deployment that launches from a directory other than the project's.

## Fixes

1. Ship the base file beside the binary, or start from the directory that holds it.
2. Or pass the location: `Configuration.load(from: URL(fileURLWithPath: "/srv/app"))`.

## Related

ALU-CONFIG-5006.
