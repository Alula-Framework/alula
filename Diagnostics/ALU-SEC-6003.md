# ALU-SEC-6003: The security module has no way to authenticate anyone

**Severity:** error

## Meaning

`AlulaSecurityModule` was built with no bearer-token validator, no token
strategies and no sessions. The application stops at startup with this code.

## Why Alula rejects it

With none of the three, no request could ever be authenticated. Every route
that requires authentication would answer 401 to everyone. The application is
misassembled, so it does not start.

## Common causes

- `AlulaSecurityModule` listed without `AlulaOIDCModule` or a module of your
  own that provides `any TokenValidator`.
- A browser sign-in application that lists a sign-in module but not
  `AlulaSessionsModule`.
- An application that builds `AlulaSecurityModule(validator: nil)` by hand.

## Fixes

1. For bearer tokens, list `AlulaOIDCModule`, or a module that provides `any TokenValidator`.
2. For API keys, list `AlulaAPIKeyModule`, which contributes a token strategy.
3. For browsers, list `AlulaSessionsModule` with a sign-in module.

## Example

```swift
await Alula.run(
    configuration: try Configuration.load(),
    modules: [AlulaWebModule<AlulaTransport>.self, AlulaOIDCModule.self, AppModule.self],
    composedBy: alulaComposeModules
)
```

## Related

ALU-SEC-6002.
