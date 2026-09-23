# Flight Sessions

Server-side session state for browser applications: a bag of values kept
under an id that a cookie carries, loaded before the handler and persisted
after it. It is where a login lives once a password has been checked, where a
cart lives before there is an order, and where a "Saved." notice waits for
the page a form redirects to.

It is **not** authentication. Flight Security Core's non-goals stay true:
sessions carry state, and turning that state into an identity is a small,
explicit step described below.

Three pieces, and you name one of them:

| | |
|---|---|
| `FlightSessionsModule` (`FlightWeb`) | The middleware and `context.session`. List it. |
| `SessionStore` (`FlightSessions`) | The seam a backend implements. `InMemorySessionStore` is the default and needs no configuration; `FlightSessionsValkey` in flight-data is the shared one; [Stores](#stores) shows how to write another. |
| `Session` (`FlightSessions`) | What a handler holds: `get`, `set`, `remove`, `flash`, `regenerate`, `destroy`. |

## Adding this module

| | |
|---|---|
| **Trait** | `Web` |
| **Products** | `FlightWeb` (the middleware and `context.session`); `FlightSessions` is brought along |
| **Module** | `FlightSessionsModule.self` |
| **Optional** | `FlightSessionsValkeyModule.self` from flight-data, for more than one replica |

```swift
// Package.swift
dependencies: [
    .package(
        url: "https://github.com/Flight-Framework/flight.git",
        from: "0.33.0", traits: ["Web"]),
],
targets: [
    .executableTarget(
        name: "App",
        dependencies: [
            .product(name: "FlightCore", package: "flight"),
            .product(name: "FlightWeb", package: "flight"),
            .product(name: "FlightTransport", package: "flight"),
        ],
        plugins: [.plugin(name: "FlightRegistrationPlugin", package: "flight")]
    )
]
```

```swift
// Sources/App/Main.swift
import FlightCore
import FlightTransport
import FlightWeb

@main
struct Main {
    static func main() async {
        await Flight.run(
            configuration: try Configuration.load(),
            modules: [
                FlightWebModule<FlightTransport>.self,
                FlightSessionsModule.self,
                AppModule.self,
            ],
            composedBy: flightComposeModules)
    }
}
```

`import FlightWeb` is enough: it re-exports `FlightSessions`, so `Session`
and its methods are in scope wherever `RequestContext` is.

## Quick start

```swift
@Controller("/account")
struct AccountController {
    @Inject var accounts: AccountService

    @PostRoute("/login")
    func login(_ context: RequestContext, body: LoginForm) async throws -> Response {
        let account = try await accounts.authenticate(body.email, body.password)
        let session = try context.requireSession()
        try session.set("account", account.id)
        session.regenerate()                       // a new id: the one from before login is not the one signed in
        try session.flash("notice", "Welcome back.")
        return .seeOther("/")
    }

    @PostRoute("/logout")
    func logout(_ context: RequestContext) throws -> Response {
        try context.requireSession().destroy()      // store entry deleted, cookie expired
        return .seeOther("/")
    }
}

@Controller("/")
struct HomeController {
    @GetRoute("/")
    func home(_ context: RequestContext) throws -> Response {
        let session = try context.requireSession()
        let notice = try session.flashed("notice", as: String.self)   // "Welcome back.", once
        let accountID = try session.get("account", as: UUID.self)      // nil when signed out
        …
    }
}
```

`context.session` is `nil` on a request no `Sessions` middleware saw;
`requireSession()` throws a 500 whose log line names the module to list.
Prefer it over unwrapping.

### What a session does, and when

- **Nothing is stored until something is written.** A request that only
  reads gets an empty session, leaves no record and sets no cookie, so
  anonymous traffic cannot fill the store.
- **The first write** mints an id, stores the record, and sets the cookie:
  `HttpOnly`, `Secure`, `SameSite=Lax`, `Path=/`, `Max-Age` equal to the
  TTL. All of it configurable below.
- **`set` to what is already there is not a write.** A handler that stores
  the same value on every request costs no store call.
- **The TTL slides.** A write renews it. A read renews it only once less
  than half of it is left, so an idle session costs one write per half-TTL
  and an active one never expires.
- **`regenerate()`** keeps the values and moves them under a new id,
  deleting the old one. Call it whenever the session's privilege changes,
  and on login above all: an id planted in a browser before authentication
  must not be the id that is authenticated afterwards.
- **`destroy()`** deletes the record and expires the cookie. Writes after it
  in the same request are discarded.
- **Removing the last value** deletes the record rather than storing it
  empty.
- **Flash** values are readable by the next request only, any number of
  times within it, and are cleared when that request ends.
- **A cookie naming nothing** — expired, deleted, never existed — is a fresh
  visit. It is indistinguishable from no cookie, because that is what it is.
  The stale cookie is replaced only if the request writes.
- **A handler's writes are committed even when its response is an error.**
  The router renders a handler's throw into a response *inside* the chain,
  so the middleware sees a 500 and persists the session that went with it.
  Write last, or `destroy()` on the way out, if failure should keep nothing.

### Concurrency

Two requests on the same cookie at the same time are last-write-wins on the
whole record; there is no per-key merge. Every session framework works this
way, and it is worth knowing before a page fires three requests that each
write.

### WebSocket routes

A socket route's lane runs `Sessions` before the upgrade, so the session is
readable during the handshake — which is how a socket learns who it is
talking to. An upgrade response cannot carry `Set-Cookie`, so a *new*
session created there is stored but its cookie never reaches the client.
Create the session on an ordinary route first.

## When the store cannot answer

A store that throws is a **503** with a generic body, on the way in and on
the way out, and the reason is in the log. This is the opposite of the
cache's fail-open rule, on purpose: a cache that fails is answered by the
real computation behind it, and nothing is behind a session. A store that
silently read empty would sign the user out without a word; a save that
silently dropped would lose a login after the handler reported success.
Refusing is honest, and the operator sees it.

A record under a well-formed id that does not decode — a store shared with
something else, or a format this version no longer reads — starts a fresh
session and logs a warning. That one is not the client's doing and not
worth refusing them for.

## Configuration reference

All keys live under `sessions.` (env-var form `FLIGHT_SESSIONS_*`), all
kebab-case, none required.

| key | default | meaning |
|---|---|---|
| `cookie-name` | `session` | The cookie the id travels in. Checked at composition against what a `Set-Cookie` name may contain |
| `ttl` | `14d` | Idle timeout, sliding. A duration string: `30m`, `12h`, `14d` |
| `cookie-secure` | `true` | The `Secure` attribute. See below |
| `cookie-same-site` | `lax` | `strict`, `lax` or `none`. `none` without `cookie-secure` is refused — browsers reject that cookie outright |
| `cookie-path` | `/` | |
| `cookie-domain` | unset | The request's host only |
| `memory.max-entries` | `100000` | The in-memory store's bound. Past it, expired entries go first, then the least recently loaded |
| `authenticated-lifetime` | `7d` | The absolute limit on a sign-in, counted from the sign-in and never renewed by activity. See *The authenticated lifetime* |
| `cookie-host-prefix` | `false` | Names the cookie `__Host-<cookie-name>`. Needs `cookie-secure`, `cookie-path: /` and no `cookie-domain`, or startup fails |

Every value is read once at composition, so a bad one fails startup rather
than the first request that sets a cookie.

### Why `cookie-secure` defaults to on

`Cookie` itself defaults `isSecure` to false, because a bare cookie API
cannot know its deployment and a cookie that silently never gets set is a
worse failure than one that is explicitly insecure in development. A session
cookie is different: it is a bearer credential, and the framework does know
what it is. Sending it over plaintext once is enough to lose the session.

The cost is a development server on plain HTTP in Safari, which drops
`Secure` cookies from `http://localhost` (Chrome and Firefox accept them).
Pay it in the dev overlay, not the base file:

```yaml
# flight-dev.yaml
sessions:
  cookie-secure: false
```

## Stores

`SessionStore` is three methods over opaque bytes — `load`, `save` with a
TTL, `delete` — and every one of them throws. A record is one JSON blob per
id; values inside it were encoded as JSON when `set` was called. Not with the
wire's `web.*` coders, and on purpose: the module used to take `WebCoders`,
and `FlightWebModule` provides that while taking this module's middleware,
which is a composition cycle the build refuses. Session bytes are read back
only by this runtime, so nothing is lost.

| Store | Where | For |
|---|---|---|
| `InMemorySessionStore` | `FlightSessions`, the default | One replica, development, tests. Bounded; lost on restart |
| `ValkeySessionStore` | `FlightSessionsValkey` in flight-data, `Valkey` trait | Any deployment with more than one replica |
| `RecordingSessionStore` | `FlightSessionsTesting` | Asserting what a request did to its session |

Configuring `sessions.valkey.url` without listing `FlightSessionsValkeyModule`
is refused at startup. The alternative — each replica quietly keeping its own
sessions — is the failure nobody notices until a load balancer signs a user
out.

### Writing a store

A store is three methods over opaque bytes, and a module that provides it.
`FlightSessionsModule` takes `store: any SessionStore` by type, so providing
one is the whole integration — the same direction the cache and PubSub
adapters use:

```swift
import FlightCore
import FlightSessions

/// Any client with get, set-with-TTL and delete — a database table with an
/// `expires_at` column, a cloud key-value service, an actor in tests.
protocol KeyValueClient: Sendable {
    func get(_ key: String) async throws -> Data?
    func set(_ key: String, _ value: Data, expiringIn ttl: Duration) async throws
    func delete(_ key: String) async throws
}

final class KeyValueSessionStore: SessionStore, Sendable {
    let client: any KeyValueClient

    init(client: any KeyValueClient) { self.client = client }

    func load(_ id: SessionID) async throws -> Data? {
        guard let data = try await client.get("session:" + id.cookieValue) else { return nil }
        // A backend without native expiry checks the record's own clock, so
        // an expired session reads as absent rather than as a ghost.
        guard try SessionRecord(decoding: data).expiresAt > Date() else {
            try await client.delete("session:" + id.cookieValue)
            return nil
        }
        return data
    }

    func save(_ id: SessionID, _ record: Data, ttl: Duration) async throws {
        try await client.set("session:" + id.cookieValue, record, expiringIn: ttl)
    }

    func delete(_ id: SessionID) async throws {
        try await client.delete("session:" + id.cookieValue)
    }
}

struct KeyValueSessionsModule: FlightModule {
    /// Matched by type to `FlightSessionsModule`'s `store:` parameter.
    let store: any SessionStore

    init(client: MyKeyValueClient) {          // whatever module provides the client
        store = KeyValueSessionStore(client: client)
    }
}
```

List `KeyValueSessionsModule.self` beside `FlightSessionsModule.self` and
the in-memory default is no longer chosen. Order does not matter.

What a store must promise:

- **Throw on failure.** Never answer `nil` for "could not ask"; `nil` means
  "there is no live session there". The middleware turns a throw into a 503
  and a `nil` into a fresh visit, and confusing the two signs users out
  silently.
- **Honour the TTL.** Native expiry (`SET … PX`, a TTL index) is the right
  shape. Without it, check the record's `expiresAt` on load and sweep on
  whatever cadence the backend prefers; `SessionRecord(decoding:)` reads
  the bytes if you need the date.
- **Treat the id as opaque and the bytes as opaque.** The id is a 43-character
  base64url string safe for any key; the record is JSON the framework owns.
- **Idempotent `delete`.** Deleting an absent id is not an error.

`FlightSessionsTesting`'s `RecordingSessionStore` is a fourth conforming
implementation, and reading it beside `ValkeySessionStore` shows the whole
contract in under two hundred lines.

## Sessions and identity

`FlightSecurityCore` establishes identity from a bearer token. A browser
has no bearer token; it has a cookie. With both modules listed, the bridge
is two calls:

```swift
try context.requireSession().signIn(principal)   // after the application checked a credential
try context.requireSession().signOut()
```

`Authentication` then finds the principal in the session on every request
that carries the cookie, and everything downstream — `context.principal`,
`requirePrincipal()`, `roles:` on a route — works as it does for a token.
`signIn` regenerates the id; a bearer token, when present, still wins.
Ordering is `FlightSecurityModule`'s: given the session runtime, it runs
`Sessions` ahead of `Authentication` in every lane it declares, and a lane
of your own that gets that backwards is refused at startup. The details are
in `Docs/security-core.md` under *Signing in with a session*.

## Signing out everywhere

Every session knows its owner, which is the subject `signIn` stored. A
store that indexes sessions by owner can end all of one person's sessions
at once. You want that after a password change, and when an account is
disabled:

```swift
// After a password change: every other browser signs in again.
try await sessions.revokeSessions(
    ownedBy: principal.subject, keeping: context.requireSession().id)

// An account disabled by an administrator: everywhere.
try await sessions.revokeSessions(ownedBy: subject)
```

`sessions` is the `SessionRuntime` that `FlightSessionsModule` provides.
Inject it where you need it.

Indexing is a capability, `OwnerIndexedSessionStore`, rather than a
requirement of `SessionStore`. A store is handed opaque bytes, and indexing
them is extra work it opts into. The in-memory store does it, and so does
flight-data's Valkey store from 0.10.0. A store that doesn't index keeps
working. Asking it to revoke throws `SessionRevocationUnsupported` rather
than ending nothing, because a "sign out everywhere" that signs nobody out
is the failure this exists to prevent.

A session with no owner encodes exactly as it did before owners existed,
so records already in a store read unchanged.

**Revocation is point-in-time.** It ends the sessions that exist when it
runs, and that's all it guarantees. Suppose one request signs in with the
old password while another changes it and revokes. The sign-in can verify
before the change and save its session after the revocation scan, and that
one session survives. To keep that window to one in-flight sign-in, change
the credential first and revoke second. The authenticated lifetime (below)
bounds whatever gets through.

A stronger guarantee is possible, but it means a per-account version that
every request checks: a store read on every authenticated request, forever,
to close a window measured in milliseconds. That's the trade D40 records.

## The authenticated lifetime

`sessions.ttl` is sliding, so an active session never idles out. That's
right for a cart and wrong for a signed-in user: a stolen cookie that's used
continuously would last forever. `sessions.authenticated-lifetime` (default
7 days) is the absolute limit on a sign-in, counted from the sign-in itself
and never renewed by activity. Past it, `Authentication` signs the session
out and the browser signs in again. The rest of the session, such as the
cart, survives.

```yaml
sessions:
  ttl: 14d                        # idle timeout, sliding
  authenticated-lifetime: 12h     # hard limit on a sign-in
  cookie-host-prefix: true        # the cookie becomes __Host-session
```

A sign-in recorded before 0.33.0 has no sign-in time. It's stamped the
first time it's seen and gets one full lifetime from then, rather than
everyone being signed out at upgrade.

`cookie-host-prefix` names the cookie `__Host-<name>`. Browsers accept that
only for a cookie that's `Secure`, has `Path=/` and no `Domain`, so no
subdomain can set or overwrite it. It's off by default, for two reasons:
renaming the cookie signs everyone out once, and a deployment that shares
its session across subdomains can't use it. Settings the browser would
reject fail at startup.

## Metrics

| Counter | Dimensions |
|---|---|
| `flight_sessions_created` | none: a new session's first save |
| `flight_sessions_regenerated` | none: sign-in, sign-out, `regenerate()` |
| `flight_sessions_store_failures` | `operation` (`load`, `save`, `delete`): each one is a 503 to someone |
| `flight_sessions_revoked` | none: counted per session ended, not per call |
| `flight_sessions_revocation_failures` | none, including a store that can't revoke |

These go through swift-metrics to whatever backend the application
bootstraps. `SessionRuntime(metrics:)` takes a factory for tests.

## One-time links

`OneTimeTokenStore` lives here too. It's the short-lived, single-use
storage behind a password-reset or email-verification link, the same kind
of thing as a session: server-side state with a lifetime that must be
shared across replicas. The token logic is `FlightSecurityCore`'s
`OneTimeTokens`, which covers hashing, purposes, binding, and redeeming
once. See `Docs/sign-in.md`. A store needs only `put` and an atomic
`take`.

## CSRF

A signed-in session is exactly what CSRF protection exists to defend —
ambient, cookie-carried authority a browser attaches automatically, to a
request an attacker's page triggers without the visitor's knowledge.
`CSRFProtection` is `FlightWeb`'s, keyed off the same session's own token,
with the same `SessionReading` ordering rule `Authentication` follows. See
`Docs/web.md` under *CSRF*.

## Testing

`RecordingSessionStore` from `FlightSessionsTesting` serves from a dictionary
and remembers every call. `SessionRuntime` takes a clock, so renewal and
expiry are tested without sleeping:

```swift
let store = RecordingSessionStore()
let runtime = SessionRuntime(store: store, settings: try SessionSettings(ttl: .seconds(3600)))
let client = try TestClient(
    routes: AccountController.flightRoutes { _ in AccountController(accounts: fakeAccounts) },
    middleware: MiddlewareRegistration.lane(.default, [Sessions(runtime: runtime)]))

let login = await client.post("/account/login", body: form)
let id = try #require(store.storedIDs.first)
#expect(try store.record(for: id)?.values["account"] != nil)
```

For a handler called directly, `RequestContext.mock(session: Session())`
hands it an empty session to write to.

## Deliberately not here

- **Client-side (signed cookie) sessions.** A 4 KB ceiling, no revocation,
  and a signing key to rotate. The server-side design needs none of those.
- **Per-key merging of concurrent writes.** See *Concurrency*.
- **A Postgres store.** Valkey has native expiry and is the store every
  other shared thing in Flight already uses. A relational store wants a
  sweeper, and nothing has asked for one yet.
