# ALU-LIFE-8002: No initializer of a module can be satisfied

**Severity:** error

## Meaning

The build found no initializer of a module whose every parameter something
in the application can supply.

## Fixes

1. Add the modules that provide the missing parameters.
2. Give the parameter a default value, or make it optional if absence is
   meaningful.
3. Add an initializer the application can satisfy.

## Related

ALU-DI-1001.
