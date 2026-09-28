# What is missing

The still-open gaps across the Alula ecosystem, re-checked against the code
on 2026-09-28 at alula 0.59.0, alula-data 0.24.0 and hangar 0.16.1. Each
entry says what is absent and roughly how big it is, so the list can be
argued with rather than just worked through.

This is the live remainder of the root `GAPS.md`, which ran from 2026-08-24
to 0.59.0 and mixed open items with closed ones and postmortems. The full
historical file, including the postmortems that CHANGELOG and DECISIONS cite
as "GAPS.md §0 gap #N" or "GAPS.md's opening story", is at
`git show v0.59.0:GAPS.md`. Section numbers here match that file.

## 0. Functional gaps: the 2026-09-24 audit

The audit asked which capabilities an application developer expects from a
mature server framework (Vapor, Hummingbird, Spring Boot, Phoenix, Rails)
that Alula lacks. Items already declined in DECISIONS.md are not repeated.

### Ranked gaps: all ten built

The numbering is kept because CHANGELOG and DECISIONS cite it.

| # | Gap | Built in |
|---|---|---|
| 1 | Durable background job queue | alula 0.38.0, alula-data 0.13.0 (D47) |
| 2 | Email delivery seam | alula 0.39.0 (D48) |
| 3 | Outbound HTTP client | alula 0.40.0 (D49) |
| 4 | Declarative request validation | alula 0.41.0 (D50) |
| 5 | Per-route request deadlines | alula 0.42.0 (D51) |
| 6 | OpenAPI emission | alula 0.43.0 (D52) |
| 7 | Read replicas from alula-data | alula-data 0.14.0 |
| 8 | Production observability defaults | alula 0.44.0 (D53) |
| 9 | Postgres-only clustering (LISTEN/NOTIFY PubSub, outbox) | alula-data 0.15.0, 0.16.0 |
| 10 | CLI beyond `new` and `migrate` | alula-cli; application commands in alula 0.45.0 (D54). `alula generate auth` is verified by hand, not in CI |

### Smaller, by area (S unless marked)

Only the items still open. Items built since the audit are listed at the end
of each area with the release that built them.

- **HTTP:**
  - Responses are JSON only: no `Accept` negotiation and no `406` (M).
  - A `Decodable` body can't be decoded from multipart.
  - No pagination envelope or `Link` headers.
  - No idempotency keys for inbound requests (M). The outbound client treats
    a request carrying `Idempotency-Key` as safe to retry, but nothing
    enforces one on the server side.
  - TLS certificates can't be reloaded without a restart (M).
  - No WebSocket compression (permessage-deflate).
  - *Built:* `If-Match` preconditions, webhook HMAC verification, WebSocket
    subprotocols and configurable pings, `204` for a plain `OPTIONS` (all
    0.46.0).
- **Data:**
  - No SQLite (L), and `InMemoryDataSource` cannot run queries.
  - Hangar has no JSONB operators, full-text search or keyset pagination.
  - No automatic timestamps, no tracing spans on queries, no seeding, and no
    general distributed lock.
  - No schema-diff migrations, and no Swift code inside migrations.
  - *Built:* bulk upsert (hangar 0.10.0). `Pagination.swift`'s doc no longer
    promises cursor reads that do not exist (hangar 0.16.1).
- **Security:**
  - Authorization is roles and scopes only: no policy or ownership checks (M).
  - No MFA (TOTP planned for phase 5; WebAuthn L).
  - mTLS verifies the client certificate but never hands it to the request (M).
  - No first-party JWT or refresh-token issuance (M).
  - No audit trail carrying subject and address. A failed sign-in is logged
    (0.48.3), which is not the same thing.
  - No breached-password check (belongs with sign-in phase 3c).
  - A socket doesn't notice when its session is revoked.
  - *Built:* an API-key validator (0.46.0), composing with `AlulaOIDCModule`
    through `tokenStrategies` since 0.48.0 (D55). *Not a gap:* JSON depth
    limits. Foundation's parser refuses nesting past 512 levels, and the body
    size limit bounds key count.
- **Messaging and integrations:**
  - No FCM or Web Push (M each).
  - No object storage or signed URLs (M).
  - No i18n (M).
  - No typed domain events or wildcard topics (M). PubSub topics are
    exact-match.
  - Channels has no replay of messages sent while a client was disconnected
    (M). The client rejoins its topics after a reconnect; it does not receive
    what it missed.
- **Core:**
  - No optional `@Inject` (the generator refuses `@Inject var x: T?`) and no
    conditional modules (M).
  - Actuator has no env endpoint and can't change log levels at runtime.
  - *Built:* start and stop hooks (`lifecycleHooks`, 0.47.0) and build info
    (`/actuator/info`, 0.47.0). *Declined:* "compose everything, swap one" for
    tests. `Docs/testing.md` explains why: a full-composition test proves the
    wiring, and a test that needs a fake builds the component directly.

**Deliberately not listed:** the HTTP, WebSocket and security items declined
in DECISIONS.md: templating, runtime route registration, a trie router,
point-in-time revocation, and issuing tokens to third parties.

## 3. Declared gaps, by library

### hangar

- **No composite-key associations.** `@HasMany` and `@BelongsTo` assume a
  single column. An entity with a composite key gets a diagnostic, and
  introspection refuses to describe a composite foreign key. *Medium, and
  nobody has asked.*

### alula-web

- **No HTTP/2 or HTTP/3.** The transport serves HTTP/1.1 only. On one
  Hummingbird listener, HTTP/2 and WebSockets are mutually exclusive: there is
  no RFC 8441 extended CONNECT. Channels are WebSockets. The upgrade seam was
  generalized in 0.4.0 (`UpgradeResponse`, `RouteRegistration.Kind.upgrade`),
  so an HTTP/2 transport would serve every existing WebSocket handler
  unmodified. The transport itself would be a second `ServerTransport`, either
  on `swift-server/swift-http-server` once its WebSocket design settles, or on
  NIOHTTP2 directly. Before investing, check RFC 8441 *client* support in
  practice (Safari and common intermediaries). Terminate HTTP/3 at a proxy
  until Apple's QUIC stack leaves prerelease. The full 2026-08-26 analysis is
  in the historical file.
- No templating or SSR. *Deliberate; out of scope.*
- No runtime route-registration API. *Deliberate.*

### alula-actuator

- No live-updating dashboard and no historical metrics. *Deliberate.*

### alula-data / drivers

- No cross-database abstraction, no auto-migration at boot, no query caching.
  *All deliberate.*
- `AlulaDataValkey` has no transaction support. *Deliberate: Valkey is not
  transactional in that sense.* (Valkey PubSub now exists, as
  `AlulaPubSubValkey`.)

### alula-channels-js

- Published to a repository, **not to npm**.
- No CI badge and no bundled build. Consumers use it as ESM source. *Fine for
  now.*

## 4. Product gaps: things that would decide adoption

Nothing open. The hangar Vapor shim, the contributor test script and
`alula new --with` all shipped. npm and Homebrew publishing are the remaining
distribution work, tracked under alula-channels-js above and in alula-cli.

## 5. Known and accepted

Recorded so they are not rediscovered as bugs:

- **Format debt.** Measured 2026-09-28 with swift-format 6.3.3:
  `swift format lint --recursive --strict Sources Tests` reports **4,267**
  violations in `alula` against the shared `.swift-format`. The lint job is
  advisory. A bulk reformat must avoid the macro fixture files, whose
  expected-expansion strings a careless regex corrupts, and should land as its
  own reviewed change. `alula-cli` is at 0 and its lint blocks. Re-measure
  rather than carrying a figure forward; `alula-data`'s last measured count
  was 1,064 on 2026-09-18.
- **One unexplained test failure**, alula-data, 2026-08-25: a single issue
  in a 375-test run that did not reproduce in ten later runs. Recorded so the
  next occurrence is the second one rather than the first.
- **Root builds need `--enable-all-traits`.** A root build compiles every
  target regardless of traits, so a plain `swift build` in `alula` or
  `alula-data` fails by design. Both READMEs say so.
- **Relative paths remain in git history.** Not sensitive. Removing them
  would mean rewriting several repositories and moving tags for no security
  benefit.
- **Old per-package repositories are archived**, with notices pointing at
  their replacements.
