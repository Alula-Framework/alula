# ``AlulaSecurityCore``

Turn a credential into a ``Principal`` on every request: a token from an
OIDC provider, an API key, or a browser session signed in with a password or
through a provider.

## Overview

The boundary is the point: whatever proves who is calling, a handler sees one
``Principal``, read off the request context with nothing to resolve. The
common case is an identity provider you already run, and there it is
configuration rather than code. When the application keeps its own accounts,
the pieces it would otherwise hand-roll — password hashing, sign-in, one-time
links, API keys — are here, behind the same seam.

``OIDCTokenValidator`` is the shipped validator, and for OIDC-compliant
providers it is configuration rather than code — Descope, Keycloak, Auth0,
Okta and Entra are all the same type with different values. List
``AlulaOIDCModule`` (which pulls ``AlulaSecurityModule`` in with it) and
name the issuer:

```yaml
security:
  oidc:
    issuer: https://example.eu.auth0.com/
    audience: https://api.example.com
```

Everything else — the JWKS endpoint, cache TTLs, the algorithm allowlist —
has a default; ``OIDCSecurityConfiguration`` is the whole list. Missing
`issuer` or `audience` fails at composition, not at the first request.

JWTKit owns the cryptographic core — signature verification, JWS structure,
JWK parsing. This module owns the orchestration around it: key fetching and
rotation, and a claim policy where issuer must match, audience must include
this application, `exp`/`nbf` are enforced with configurable clock-skew
leeway, and `sub` is required.

## When your provider is not OIDC

``TokenValidator`` is one method — token in, ``Principal`` out. Conform to it,
have a module of your own hold the value as `any TokenValidator`, and list
``AlulaSecurityModule`` rather than ``AlulaOIDCModule``; composition hands it
over by type:

```swift
struct OpaqueTokenValidator: TokenValidator {
    let introspection: IntrospectionClient

    func validate(_ token: String) async throws -> Principal {
        let grant = try await introspection.lookup(token)
        return Principal(subject: grant.userID, issuer: "introspection", roles: grant.roles)
    }
}
```

A validator for one kind of token beside another, such as API keys beside
OIDC, is a ``TokenStrategy``: it recognises its own tokens and the rest go to
the validator. ``AlulaAPIKeyModule`` contributes one.

``JWKSSource`` is the narrower seam, for a provider that publishes keys
somewhere non-standard: keep the OIDC claim policy, change only where keys
come from. ``HTTPJWKSSource`` is the default, using OIDC discovery.

## Identity rides the request

The authentication middleware writes the ``Principal`` onto the copy of the
request context it passes downstream, so a handler reads it off the context
with nothing to resolve and nothing shared between requests:

```swift
@GetRoute("/orders")
func orders(_ context: RequestContext) async throws -> Response {
    let principal = try context.requirePrincipal()   // 401 when absent
    return try .json(await orders.forOwner(principal.subject))
}
```

For service code that should not take a principal parameter, bind the
task-local around the call with `context.withPrincipal { ... }` and read
``Principal/current`` inside.

The web layer stores this as a `RequestIdentity` (Alula Web) behind a
two-member seam protocol, because `RequestContext` cannot name ``Principal``
without a dependency cycle — the same shape `AlulaChannels` uses for
`ChannelPrincipal` (Alula Channels).

``AuthenticationState`` distinguishes *anonymous* from *authenticated*
rather than collapsing both into a nil check, so a route that genuinely
allows anonymous access says so.

## Authentication is not enforcement

``Authentication`` establishes identity and rejects nobody, so a public route
stays public with the middleware in place. ``RequireAuthentication`` is the
part that says no, and it runs where a route asks for it —
``AlulaSecurityModule`` declares the two canonical lanes and a controller or
route names one:

```swift
@Controller("/admin", pipelines: [.authenticated])      // 401 for anonymous
struct AdminController {
    @GetRoute("/status", pipelines: [.public])          // deliberate, and says so
    func status(_ context: RequestContext) -> Response { .text("ok") }
}
```

`.authentication` is the other: identity established, nobody rejected, for a
route that serves signed-in and anonymous callers differently. Authorization
stays in the handler — `requireRole` and `requireScope` depend on a value, and
no lane can describe that.

## Key rotation is a liveness concern

A provider rotates its signing keys, and a validator that caches them
forever starts rejecting every valid token. ``OIDCSecurityConfiguration``
exposes the whole policy — cache TTL, refresh cooldown, and a maximum stale
age past which a cached key set is refused rather than trusted. The cooldown
is what stops a burst of tokens signed by an unknown key from becoming a
burst of JWKS fetches.

``JWKSTransportPolicy`` governs the fetch itself. It requires HTTPS by
default; relaxing that is possible and deliberately awkward.

## What it does not do

No login page, no OAuth authorization server, no access or refresh tokens
of its own. ``PasswordSignIn`` checks a password your form posts and puts the
principal in the session; issuing bearer tokens to other clients is your
identity provider's job. The sessions themselves are `AlulaSessions`'.

`AlulaChannels` reuses that boundary — a `Principal` established during a
WebSocket's HTTP upgrade is what the channel's join sees.

## Topics

### Validating a token

- ``TokenValidator``
- ``TokenStrategy``
- ``CompositeTokenValidator``
- ``OIDCTokenValidator``
- ``OIDCSecurityConfiguration``
- ``TokenValidationError``

### Hashing a password

- ``PasswordHashing``
- ``Argon2idHashing``
- ``PasswordHashingError``

### Signing in

One seam, two providers: the application's own accounts, or any OpenID
Connect provider. Both produce a ``Principal`` with the same standard
claims, so switching is a change to the module list. Docs/sign-in.md has
the whole story.

- ``SignInProvider``
- ``SignInStep``
- ``SignInForm``
- ``SignInResult``
- ``SignOutStep``
- ``RedirectNegotiation``
- ``SignInReturnPath``
- ``SignInEvents``
- ``SignInMetrics``
- ``PasswordSignIn``
- ``OIDCSignIn``
- ``OIDCSignInConfiguration``
- ``OIDCSignInError``

### Accounts and passwords

- ``CredentialStore``
- ``StoredCredential``
- ``InMemoryCredentialStore``
- ``PasswordAuthenticator``
- ``PasswordAuthenticationError``
- ``OneTimeTokens``
- ``OneTimeTokenError``

### Webhooks

- ``WebhookSignature``
- ``VerifyWebhookSignature``
- ``WebhookConfigurationError``

### API keys

- ``APIKeys``
- ``APIKeyStore``
- ``InMemoryAPIKeyStore``
- ``APIKeyValidator``
- ``AlulaAPIKeyModule``

### Where keys come from

- ``JWKSSource``
- ``HTTPJWKSSource``
- ``JWKSTransportPolicy``
- ``JWKSSourceError``

### Identity

- ``Principal``
- ``AuthenticationState``

A browser signs in once and is authenticated by its cookie afterwards:
`Session.signIn(_:)` stores the principal, `signOut()` forgets it, and
``Authentication`` reads it when no bearer token is present. Both are
extensions on `AlulaSessions.Session`; Docs/security-core.md has the flow.

### Enforcement

- ``Authentication``
- ``RequireAuthentication``
- ``SecurityError``

### Hosting

- ``AlulaSecurityModule``
- ``AlulaOIDCModule``
- ``AlulaPasswordSignInModule``
- ``AlulaOIDCSignInModule``
