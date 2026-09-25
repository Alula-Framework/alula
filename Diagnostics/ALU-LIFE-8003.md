# ALU-LIFE-8003: A module contributes something nothing collects

**Severity:** error

## Meaning

A module exposes a contribution — `[ChannelRegistration]`, routes,
scheduled jobs — and no module in the application takes a list of that type,
so the contribution would be silently dropped.

## Fixes

Add the module that collects it to `modules:` (the diagnostic names it).
