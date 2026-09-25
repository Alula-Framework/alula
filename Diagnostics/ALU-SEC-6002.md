# ALU-SEC-6002: Several modules provide the bearer-token validator

**Severity:** error

## Meaning

Two or more included modules each provide `any TokenValidator` — say, one for
single sign-on and one for partner API tokens.

## Why Alula rejects it

An application has one `any TokenValidator`: the fallback for bearer tokens no
strategy claims. Choosing one with `defaultProviders` would silently switch
the other method off. Authentication methods are meant to sit side by side as
token strategies, each recognizing its own tokens, so that is the fix rather
than a wiring choice.

## Common causes

- Adding a second authentication module that was written before token strategies existed.

## Fixes

1. Keep one module's `any TokenValidator` as the fallback.
2. Have each other method contribute `let tokenStrategies: [TokenStrategy]`, recognizing its tokens cheaply — by prefix, for example — as `AlulaAPIKeyModule` does.

## Example

```swift
struct PartnerTokensModule: AlulaModule {
    let tokenStrategies: [TokenStrategy]
    init(store: any PartnerTokenStore) {
        tokenStrategies = [TokenStrategy("partner", recognizes: { $0.hasPrefix("pt_") },
                                         validator: PartnerTokenValidator(store: store))]
    }
}
```

## Related

ALU-DI-1002.
