# ALU-DI-1019: @Inject or @ConfigValue on something other than a stored instance property

**Severity:** error

## Meaning

`@Inject` or `@ConfigValue` is attached to a static property, a computed
property, a property with an initial value, or something that is not a
property at all.

## Why Alula rejects it

The generated initializer assigns these properties when the instance is
built. A static property has no instance; a computed one has no storage;
an initial value would be overwritten, so it would only mislead.

## Fixes

1. Make it a stored instance property with a written type and no initial value.
2. For a static or computed value, drop the attribute and set it where it is used.

## Example

```swift
@Inject var clock: Clock                 // right
@Inject static var clock: Clock          // ALU-DI-1019
@Inject var clock: Clock = SystemClock() // ALU-DI-1019
```

## Related

ALU-DI-1016.
