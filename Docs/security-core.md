# Flight Security Core

Federated authentication for Flight, per
Flight Web.

Flight Security Core turns an externally issued identity token into a
`Principal`, makes that principal available on the request, and provides the
enforcement point for authentication — plus the *seam* (not the engine) for
authorization. Signing people in — against the application's own accounts
or through an external provider, behind one seam — is `Docs/sign-in.md`.
Account lifecycle (registration, recovery) is not built yet.

What this package owns is narrow and standard: **validate a token**. Even
that delegates its cryptographic core to [JWTKit](https://github.com/vapor/jwt-kit)
(SSWG Graduated, SwiftCrypto-backed); Flight owns only the orchestration —
JWKS fetching/rotation, claim policy, and error hygiene.

## Adding this module

| | |
|---|---|
| **Trait** | `Security` |
| **Products** | `FlightSecurityCore` |
| **Module** | `FlightOIDCModule.self` |
| **Pulls in** | `FlightSecurityModule` |

```swift
// Package.swift
dependencies: [
    .package(
        url: "https://github.com/Flight-Framework/flight.git",
        from: "0.30.0", traits: ["Security"]),
],
targets: [
    .executableTarget(
        name: "App",
        dependencies: [
            .product(name: "FlightCore", package: "flight"),
            .product(name: "FlightWeb", package: "flight"),
            .product(name: "FlightTransport", package: "flight"),
            .product(name: "FlightSecurityCore", package: "flight"),
        ],
        // Required. It scans this target for the Flight macros and writes
        // `flightComposeModules`; without it there is no composition root
        // to pass to `Flight.run`.
        plugins: [.plugin(name: "FlightRegistrationPlugin", package: "flight")]
    )
]
```

```swift
// Sources/App/Main.swift — *not* `main.swift`, which is top-level code and
// cannot coexist with @main.
import FlightCore
import FlightTransport
import FlightWeb
import FlightSecurityCore

@main
struct Main {
    static func main() async {
        await Flight.run(
            configuration: try Configuration.load(),
            modules: [
                FlightWebModule<FlightTransport>.self,
                FlightOIDCModule.self,
                AppModule.self,
            ],
            composedBy: flightComposeModules)
    }
}
```

`Security` enables `Web` — naming it is enough; you do not name both.

`FlightOIDCModule` is the batteries-included path: it reads `security.oidc.*`
and builds a validator. To bring your own, list `FlightSecurityModule` instead
and hand it a `TokenValidator`.

The `modules:` list names roots, not an order — the build resolves the
dependency DAG. A module you write can declare framework modules in its own
`dependencies`, in which case listing yours is enough.

## Quick start

```swift
import FlightCore
import FlightSecurityCore
import FlightWeb

await Flight.run(
    configuration: try Configuration.load(),
    modules: [
        FlightWebModule<FlightTransport>.self,
        FlightOIDCModule.self,
        AppModule.self,
    ],
    composedBy: flightComposeModules
)
```

```yaml
# flight.yaml
security:
  oidc:
    issuer: "https://example.descope.com"   # or Keycloak realm URL, Auth0 domain, …
    audience: "my-flight-app"
```

That's the whole provider integration: OIDC-compliant IdPs are
*configuration* of the one generic validator, not separate packages
(design). The JWKS endpoint is resolved automatically via OIDC
discovery (`{issuer}/.well-known/openid-configuration`); set
`security.oidc.jwks-url` only for a non-discoverable setup.

### Reading the current user

```swift
@GetRoute("/documents")
func documents(_ context: RequestContext) async throws -> Response {
    let principal = try context.requirePrincipal()          // 401 when absent
    return .json(try await repository.documents(ownedBy: principal.subject))
}
```

`context.principal` is `nil` for unauthenticated requests;
`context.authenticationState` additionally distinguishes "no credential"
from "rejected credential".

For service code that shouldn't take a principal parameter, bind the
task-local around the call:

```swift
@GetRoute("/documents")
func documents(_ context: RequestContext) async throws -> Response {
    try await context.withPrincipal {
        .json(try await documentService.currentUsersDocuments())
    }
}

@Service
final class DocumentService {
    func currentUsersDocuments() async throws -> [Document] {
        guard let principal = Principal.current else { throw SecurityError.unauthenticated }
        return try await repository.documents(ownedBy: principal.subject)
    }
}
```

`Principal.current` propagates to structured child tasks (`async let`, task
groups) but **not** across `Task.detached` — deliberately: a detached
background job should not silently inherit the requester's identity.

### Enforcement

Authentication and enforcement are separate concerns: `Authentication`
continues whether or not a token was presented or valid, so public routes
stay public. Reject where you choose to.

`FlightSecurityModule` puts `Authentication` in the default lane and declares
two more (Flight Web §"Middleware lanes"), so enforcement is a lane a
controller or route names:

```swift
// Identity required — `Authentication` then `RequireAuthentication`:
@Controller("/admin", pipelines: [.authenticated])
struct AdminController {
    @GetRoute("/health", pipelines: [.public])   // deliberate, and says so
    func health(_ context: RequestContext) -> Response { .text("ok") }
}

// Identity established, nobody rejected — for a route that serves
// signed-in and anonymous callers differently:
@Controller("/articles", pipelines: [.authentication])
struct ArticleController { … }
```

A lane is the whole stack for a route that names it alone, so both lanes
begin with `Authentication` rather than assuming the default lane also ran.
Naming `[.default, .authenticated]` would run `Authentication` twice — once
per lane — which costs a second validation of the same token; name the lane
alone unless the default lane carries something the route needs.

### Roles are declared on the route

A role requirement is a property of the endpoint, so it is written where the
endpoint is rather than as the first four lines of the handler:

```swift
enum AppRole: String, RouteRole { case admin, billing }

@Controller("/admin", roles: [AppRole.admin])
struct AdminController {
    @PostRoute("/users")                                  // needs admin
    func createUser(_ context: RequestContext, body: NewUser) async throws -> Response {
        try .json(await users.create(body), status: .created)
    }

    @GetRoute("/invoices", roles: [AppRole.billing])      // needs admin AND billing
    func invoices(_ context: RequestContext) async throws -> [Invoice] {
        try await billing.invoices()
    }
}
```

**Nothing extra wires this to OIDC.** `Principal` conforms to
`RequestPrincipal`, the authentication middleware writes it onto
`context.identity`, and the check the macro emits reads it from there — so
the roles claimed by the token are the roles the route tests. Which claims
become roles is the `roles-claim` key in the reference below.

An anonymous request is 401; an authenticated one without the role is 403
naming what would have been enough. Roles **add** rather than replace, so a
controller's requirement cannot be widened by a route beneath it, and
`roles:` on a `.public` route is a build error — a lane that establishes no
principal can only ever reject. The full semantics are in `Docs/web.md`.

### Signing in with a session

A browser has no bearer token; it has a cookie. With `FlightSessionsModule`
listed, the credential check happens once — a password form, an OIDC
callback, a magic link, whatever the application does — and the resulting
`Principal` is stored in the session:

```swift
@PostRoute("/login")
func login(_ context: RequestContext, body: LoginForm) async throws -> Response {
    let account = try await accounts.authenticate(body.email, body.password)
    try context.requireSession().signIn(
        Principal(subject: account.id.uuidString, issuer: "myapp", roles: account.roles))
    return .seeOther("/")
}

@PostRoute("/logout")
func logout(_ context: RequestContext) throws -> Response {
    try context.requireSession().signOut()
    return .seeOther("/")
}
```

From then on `Authentication` finds the principal in the session on every
request that carries the cookie, and `context.principal`,
`requirePrincipal()` and `roles:` work exactly as they do for a token. A
bearer token, when present, still wins — it is the fresher claim.

`signIn` regenerates the session id, every time, because an id handed out
before authentication must not be the one that is authenticated afterwards.
`signOut` forgets the principal and regenerates again, keeping the rest of
the session; `destroy()` is the stronger form. What is stored is the stable
identity — subject, issuer, roles, scopes — and not the token's `claims`,
which describe a token nobody has any more.

**Nothing has to be ordered by hand.** `FlightSecurityModule` takes the
session runtime by type in composition, and when it has one, every lane it
declares runs `Sessions` ahead of `Authentication`. `Sessions` is idempotent,
so the default lane carrying it twice — once from each module — costs one
load. A lane of your own that lists `Authentication` before `Sessions` is
refused at startup, naming the route and both layers: `Authentication`
conforms to `SessionReading`, and dispatch checks every route's chain.

`RequireAuthentication` still answers a bare 401 with a `Bearer` challenge.
A browser application wants that to be a redirect to the login page, which
is what the `ErrorMapper` that reads the request is for (Flight Web
§"Redirects").

### What a role cannot express, the handler still does

Whether this user may see *this* invoice is a fact about data, not a claim on
a token, and no declaration can state it:

```swift
@GetRoute("/invoices/:id")
func invoice(_ context: RequestContext, id: UUID) async throws -> Invoice {
    let principal = try context.requirePrincipal()        // 401 when absent
    guard let invoice = try await invoices.find(id) else {
        throw HTTPError(.notFound, "no invoice \(id)")
    }
    guard invoice.ownerID == principal.subject else { throw SecurityError.forbidden }
    return invoice
}
```

`requirePrincipal()`, `requireRole(_:)` and `requireScope(_:)` are for
exactly this — ownership, tenancy, a rule that reads a row before it can
decide. `requireRole` remains the handler-side spelling of what `roles:` says
declaratively; reach for it when the requirement is computed rather than
fixed.

**Scopes have no declarative form.** There is no `scopes:` on a route, so a
scope requirement is `try context.requireScope("invoices:write")` in the
handler. That is an omission rather than a decision, and worth knowing before
you design around it.

`RequireAuthentication` answers with a bare 401 plus an RFC 6750
`WWW-Authenticate: Bearer` challenge (`error="invalid_token"` when a
credential was presented and rejected — and no further detail).
`SecurityError.unauthenticated` / `.forbidden` thrown from handlers render
as generic 401/403.

## Configuration reference

All keys live under `security.oidc.` (env-var form `FLIGHT_SECURITY_OIDC_*`):

| key                     | required | default | meaning |
|-------------------------|----------|---------|---------|
| `issuer`                | yes      | —       | Must equal the token's `iss` exactly |
| `audience`              | yes      | —       | Token's `aud` must include it |
| `jwks-url`              | no       | OIDC discovery | Explicit JWKS endpoint |
| `jwks-cache-ttl`        | no       | `3600`  | Seconds keys stay fresh |
| `clock-skew-leeway`     | no       | `60`    | Seconds of leeway on `exp`/`nbf` |
| `jwks-refresh-cooldown` | no       | `30`    | Minimum seconds between JWKS fetches |
| `jwks-max-stale`        | no       | `21600` | Seconds a cached key set may be served while the IdP is unreachable |
| `jwks-transport`        | no       | `https_only` | `https_only`, `allow_insecure_loopback`, `allow_insecure_anywhere` |
| `roles-claim`           | no       | `roles,groups,realm_access.roles` | Comma-separated claim names/dot-paths, unioned |
| `scopes-claim`          | no       | `scope,scp` | Same; space-delimited strings are split |
| `allowed-algorithms`    | no       | every asymmetric algorithm JWTKit verifies | Comma-separated `alg` allowlist — see *Algorithms* below |

These keys shipped snake_case (`jwks_url`), following OIDC's own spec
vocabulary, while every other namespace in Flight is kebab-case
(`flight.channels.heartbeat-timeout-seconds`, `web.json.date-strategy`).
**Both spellings are read.** Kebab-case is canonical and wins if both are
set; the snake_case spelling keeps working. The inconsistency was invisible
until someone wrote `jwks-url` from habit and got the default instead of
their value — and nothing could catch that, because `Configuration` cannot
enumerate its keys, so an unknown *key* cannot be refused the way an
unrecognized *value* is.

Missing required keys fail at composition — startup, not first request.
An unrecognized `jwks_transport` value fails there too, rather than falling
back to a weaker setting than the operator wrote.

### Why the transport keys matter

Whoever answers the JWKS fetch chooses the public keys that verify every
token this service accepts. Someone able to intercept it serves their own
signing key and mints any principal they like, so `jwks_transport` is not a
hardening preference — it is the boundary the rest of this package's
guarantees sit behind. HTTPS is enforced on the discovery document, on the
`jwks_uri` it names, on an explicitly configured `jwks_url`, and on every
redirect hop the fetch actually follows.

`allow_insecure_loopback` exists for a local IdP container in development:
plaintext to `localhost`/`127.0.0.1`/`::1` and nowhere else, on the
reasoning that anyone able to intercept loopback traffic is already running
as you. `allow_insecure_anywhere` has no safe use against a remote host.

### Why stale keys expire

When a refresh fails, cached keys keep serving so an IdP blip does not take
the service down. That window is bounded by `jwks_max_stale`: past it, every
request fails — not only the one that happens to attempt the refresh. The
bound used to be checked on the refresh path alone, and refreshes are
cooldown-gated, so past the limit roughly one request per cooldown window was
refused while the rest went on validating against keys that might have been
revoked. Unbounded, a revoked key stays honored for as long
as the outage lasts — which is the exact window revocation exists to close.
Six hours is long enough to ride out a real outage and short enough that a
revocation takes effect the same day.

### Algorithms

A token's `alg` must be in `security.oidc.allowed_algorithms`, which defaults
to every asymmetric algorithm JWTKit verifies (`RS*`, `PS*`, `ES*`, `EdDSA`).
Narrow it to what your IdP issues:

```yaml
security:
  oidc:
    allowed_algorithms: RS256
```

The classic reason for an allowlist — an RS256 token replayed as HS256 with
the public key as the HMAC secret — is not reachable here: verification keys
come solely from the JWKS, and JWTKit's `JWK` has no symmetric type. That is
three separate facts staying true, though, and this is one check. The half
that earns its keep day to day is the narrowing: an IdP that starts issuing
something new does not silently start being trusted for it.

### Keys the IdP did not publish for signing

A JWK may carry `use` (`sig`/`enc`) or `key_ops`. Keys not published for
signature verification are dropped from the verification set rather than
being trusted to verify tokens — the cross-protocol mistake those fields
exist to prevent. Matched by position rather than by `kid`, since `kid` is
optional in RFC 7517 and a key without one used to slip through the filter.
A key set where *no* key carries a `kid` is legal and usable: tokens without
a `kid` are verified by trying every key in the set.

Claim-name entries match an exact top-level claim first (so Auth0-style
namespaced claims like `https://example.com/roles` work), then as a dot-path
into nested objects (Keycloak's `realm_access.roles`).

## What the validator enforces

For every request bearing `Authorization: Bearer <jwt>`:

- **Signature** — verified by JWTKit against the issuer's JWKS. `alg: none`
  is rejected outright; tokens without a `kid` are checked against all keys
  rather than trusting a default-key fallback.
- **Key rotation** — an unrecognized `kid` triggers one JWKS refetch,
  rate-limited by `jwks_refresh_cooldown` so garbage tokens can't hammer the
  IdP. Keys are cached process-wide for `jwks_cache_ttl`; a maintenance
  service pre-warms them at startup and refreshes on the TTL cadence. If the
  IdP blips, cached keys serve stale rather than failing every request.
- **Claims** — `iss` equals the configured issuer; `aud` (string or array)
  includes the configured audience (missing `aud` is a rejection); `exp`
  required and enforced, `nbf` enforced when present, both with
  `clock_skew_leeway`; `sub` required and non-empty.
- **Error hygiene** — the wire sees a generic 401 (or an anonymous
  `.continue` on unguarded routes); the precise reason
  (`TokenValidationError`) goes to the internal log only.

## Choosing how tokens are validated

`FlightSecurityModule` wires authentication — the request-scoped principal and
the `Authentication` middleware — but provides **no validator**. How tokens
are validated is chosen by listing a module:

- **`FlightOIDCModule`** for OIDC/JWT. It builds `OIDCTokenValidator` from
  `security.oidc.*` in its own initializer and owns the JWKS maintenance
  service, which takes that validator directly. It depends on
  `FlightSecurityModule`, so listing it alone is enough. Because the validator
  is built when the module is, bad `security.oidc.*` configuration fails at
  composition — startup, not the first request.
- **A module of your own** that provides `(any TokenValidator)`, for API
  keys, mTLS, HMAC, or anything else that arrives as a bearer string. (A
  session cookie is not one of these any more — see *Signing in with a
  session* above.)

```swift
struct MyValidatorModule: FlightModule {
    // Provided as a value; the composition root matches it to
    // FlightSecurityModule's `validator:` parameter by type.
    let tokenValidator: any TokenValidator = MyValidator()
}
```

List it alongside `FlightSecurityModule` — **order does not matter**, and no
`security.oidc.*` configuration is required when `FlightOIDCModule` isn't
listed.

With neither, there is no `(any TokenValidator)` to supply, and
`FlightSecurityModule` cannot be built — its initializer requires one, so
composition fails at startup, naming the type.

> **Changed.** Previously `FlightSecurityModule` registered OIDC *unless* it
> found that you had already registered your own, by scanning the container.
> That required your module to be configured **before** it — register after,
> and your validator silently lost — and an internal flag decided whether the
> JWKS refresher ran. Choosing a module is explicit and order-independent.

## Implementation notes worth knowing

The design sketches `Principal.$current.set(principal, in: context.scope)` —
a task-local bound "to a scope". When this was implemented the middleware
chain was a flat sequential loop, so a task-local bound inside the
authentication middleware unwound before the handler ran. The implemented
mechanism keeps the intended semantics with the real APIs:

- The principal rides `RequestContext.identity`, written by the
  authentication middleware into the copy it passes downstream and read
  through `context.principal`. It was a `.scoped` `PrincipalHolder`
  component until the composition migration; the container was inverting a
  dependency (`RequestContext` is Flight Web's, `Principal` is this
  package's) that a seam protocol expresses directly.
- `Principal.current` still exists as a task-local; handlers opt in with
  `context.withPrincipal { ... }`, which binds it around service calls. The
  `Task.detached` caveat from design applies unchanged.
- `context.request.bearerToken` is provided by this package (RFC 6750
  parsing); `.respond(.unauthorized)` from the sketch is spelled
  `.respond(.problem(status: .unauthorized, message: "Unauthorized"))` with
  the real Flight Web response API.

**That constraint is gone.** `Middleware.handle(_:next:)` is layered:
`compose(_:around:)` folds the chain right-to-left, so each layer calls
`next(context)` with the rest of the chain inside its own extent. A
task-local bound around `next` therefore encloses the handler, and nothing
downstream reads the principal after the chain unwinds — `errorResponse` uses
the coders, the error mapper and the logger, and never touches it. The
composition migration replaced the holder with the typed `RequestContext.identity`
value described above.

## Hashing a password

`PasswordHashing` is the one piece of a first-party credential story that
exists here so far — not a `CredentialStore`, not a login route, just the
primitive underneath either: turning a password into something safe to
store, and checking one against it later.

```swift
let hasher = Argon2idHashing()                     // OWASP's default cost parameters
let stored = try hasher.hash(newPassword)            // save the whole string
let signedIn = hasher.verify(attempt, against: stored)  // never throws: no match is "false", not an error
```

`Argon2idHashing` wraps the actual Argon2 reference implementation — the C
source the algorithm's own designers publish and that RFC 9106 is built
from, not a Swift reimplementation — the same posture as delegating JWT
verification to JWTKit. Vendored into Flight's own tree rather than an
external package dependency (`Sources/Security/CArgon2`, six files, copied
verbatim); `needsRehash` says when a stored hash was made under
weaker parameters than the app is configured with now, so raising the cost
over time upgrades each account the next time its owner signs in rather
than needing a migration that touches every row at once:

```swift
if hasher.needsRehash(stored) {
    account.passwordHash = try hasher.hash(attempt)   // only possible here: the plaintext is in hand
}
```

Password sign-in built on it — a `CredentialStore` over the application's
own accounts, a throttled `PasswordAuthenticator`, and the `SignInProvider`
seam that makes it interchangeable with an external provider — is
`Docs/sign-in.md`.

## Non-goals

No account model — the application's users stay its own, reached through
`CredentialStore` — no authorization engine in v1, no per-vendor packages
for OIDC-compliant providers (each is configuration of the one generic
validator and the one generic sign-in), no token issuance, no TLS opinions.

"No first-party credential checking" was a non-goal until 0.31.0 reversed
it on purpose: an application should be able to start on its own accounts
without running an identity provider, and move to one later without
rewriting its sign-in. D39 records why, and what keeps the switch cheap.

"No hand-rolled cryptography" is upheld, not reversed, by `Argon2idHashing`:
the algorithm is delegated to its own reference implementation, exactly as
JWT verification is delegated to JWTKit. Vendoring that implementation's
source rather than depending on it externally is a packaging decision, not
a cryptographic one — see D37 in `DECISIONS.md`.

## Development

Flight Security Core is a target of the `flight` package, not a package of
its own, and its dependencies are gated behind the `Security` trait:

```sh
swift build --enable-all-traits
swift test  --enable-all-traits --filter FlightSecurityCoreTests
# hermetic: in-memory JWKS/HTTP fakes, injected clocks — no network, no clock skew
```

Depends on `FlightCore` and `FlightWeb`, plus JWTKit and AsyncHTTPClient
(both SSWG).
