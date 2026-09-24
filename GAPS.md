# What is missing

An audit of every library in the ecosystem, written 2026-08-24 against the
v0.1.2 tags, and **last reconciled with the code on 2026-09-18 at alula
v0.20.0, alula-data v0.6.0, hangar v0.6.0, swift-changeset v0.2.1.** Each entry says what is absent, why it matters, and how much work
it looks like — so the list can be argued with rather than just worked
through.

Ordered by consequence, not by library. It lives here, in the flagship
repository, because it covers the whole ecosystem — `alula`, `alula-data`,
`hangar`, `swift-changeset`, `alula-cli` and the JS client. It was written
in `alula-cli` only because that happened to be the working directory the
day it was started; its history moved with it. Entries closed overnight on
2026-08-24/25 are marked ✅ with what actually landed; three entries in the
first draft were **wrong** and are struck rather than deleted, because the
useful thing about a wrong entry is knowing it was wrong.

**Still open, in rough priority order:** the functional gaps from the
2026-09-24 audit (next section) — production observability defaults next (gaps 1–7 are built, D47–D52 and alula-data 0.14.0); then alula-web
HTTP/2 (a design decision, not a task — see below); hangar composite-key
associations; npm and Homebrew publishing; format debt — `alula` **1,725**
violations and `alula-data` **1,064**, measured 2026-09-18, deliberately
deferred because a bulk reformat corrupts the macro fixtures' expected-expansion
strings and should land as its own reviewed change.

**Closed 2026-09-18:** two providers of one type, in alula **v0.21.0** —
`@Inject(from:)` names a provider by module type and
`AlulaModule.defaultProviders` says which one an unqualified `@Inject` means.
The root cause was a bug rather than a missing feature: module identity
discarded generic arguments, so `PostgresDataModule<PrimaryDataSource>` and
`<Analytics>` collapsed to one binding and alula-data's documented
multi-datasource shape had never composed. DECISIONS.md D27 records the
rejected alternatives.

**Two entries left that list on 2026-09-18**, both checked against the code
rather than assumed. The distributed PubSub adapter — nominated above as *the
single highest-value gap* — ships as `ValkeyPubSubAdapter` in alula-data's
`AlulaPubSubValkey`, with `AlulaPubSubValkeyModule` wiring it, so Channels
across nodes, Presence membership and `ClusteredPubSub` all have something real
behind them. The three-way duplication of macro injection scanning is gone into
`AlulaMacroSupport`. Neither closure was recorded here, which is the thing this
file exists to do.

**Closed since this was written:** the scheduler (alula 0.2.0/0.2.1, with the
Postgres coordinator in alula-data 0.2.0 and a tutorial stage), the target
regrouping, DocC coverage and its CI jobs, the macOS jobs, and alula-web
static-file handling.

**A full source audit ran on 2026-08-29** against v0.9.1 — every file under
`Sources/`, ten reviewers, one per product, with this file and the per-product
docs as the promise baseline. Its findings were worked through in 0.10.0. The
shape of what it found is worth recording even now that the individual items
are fixed: **the code was in better shape than the prose about it.** Where the
code was wrong it clustered — three of the four highest-severity defects were
in the Scheduler, and two of the four were bounds that existed but were
checked on only one of the two paths that needed them (JWKS max-stale on the
refresh path but not the cached-return path; response backpressure in the
request direction but not the response direction). That asymmetry is now a
thing to look for: **when a defect class is closed on one side of a symmetry,
ask what its mirror image is.**

**The Container→composition rewrite (0.15.0–0.17.0) is the largest change since
this file was written**, and it appears above only in passing. The runtime DI
container is gone: modules are values that hold what they provide and take what
they need, a build plugin generates the composition root, and wiring is a
compile error rather than a resolution failure on the first request. It closed
whole classes of gap listed below — anything phrased as "registered", "resolved"
or "scoped" is describing a mechanism that no longer exists — and opened the
one the 2026-09-17 audit named: **a feature ships inert and every check passes**,
because a test can exercise the code around a seam the production path uses.

**A second full source audit ran on 2026-09-17** against v0.19.0 — eight
reviewers, same method. Its fix-first list is closed. Worth carrying forward
from it: the worst finding was that a regression guard for this project's own
named defect class had been *deleted* and nothing noticed, and the second worst
was that the docs CI job had been red on main since 2026-09-09 and nothing
noticed either. A check nobody reads is indistinguishable from no check.

**DocC is done** where it makes sense: 17 of alula's 20 targets, 8 of
alula-data's, hangar and swift-changeset. The three alula targets without
catalogues are the two macro implementations and the registration generator,
which have no consumer-facing API.

**Both former decisions are done:** hangar v0.2.0 is tagged and
`hangar-vapor` is published. Released since: alula 0.2.0 and 0.2.1,
alula-data 0.2.0, hangar 0.2.0, swift-changeset (nested changesets and
optimistic locking, untagged).

### ⚠ A feature shipped inert, and every check passed
`@Scheduler` went out in alula 0.2.0 with 743 passing tests, a DocC
catalogue, a prose guide and compiled snippets — and did nothing. The build
plugin's `registrableAttributes` did not list `Scheduler`, so the macro's
`_alulaRegister` thunk was never called and jobs never ran.

Nothing caught it because every scheduler test called `_alulaRegister` by
hand, which is exactly the step the bug skips. What caught it was *booting the
demo*, which printed `scheduler started with no jobs`.

Fixed in 0.2.1. The regression test reads both sides out of the sources —
every macro emitting a registration thunk must appear in the generator's list
— so it also covers the next registering macro somebody adds. Recorded here
because the lesson generalises: a suite, a docs build and compiled snippets
can all pass *above* the layer that is broken, and the tutorial was the only
artifact exercising the real path end to end.

**The class was still open in two more places, found by the 2026-08-29 source
audit and closed in 0.10.0.**

`OverlapPolicy` was a no-op. Every test called `JobRunner.fire()` directly,
which is precisely the seam the bug was behind: the production loop awaited
each firing before computing the next, so `isRunning` could never be true and
`.skip` never skipped. `.queue`'s documented "waits for the running job, then
runs again" simply did not happen — a feature with an API, a doc table row
and tests, doing nothing.

A route-mapping attribute on a non-`@Controller` type — or in an extension of
one — compiled cleanly, registered nothing, and produced no diagnostic
anywhere. No fixture covered it, for a reason worth writing down: a fixture
for that case has no expansion to assert and no diagnostic to assert, so it
looks like there is nothing to test. There was: the *absence* of both is the
bug.

The generalisable part is the same each time — **test through the seam the
production path uses, not around it** — plus a second rule these two add:
when a feature can be inert, write the test that fails if it produces nothing.

---

## 0. Functional gaps — the 2026-09-24 audit

Everything above this section is about whether the ecosystem does what it
claims. This one asks what it does *not* claim: which capabilities an
application developer expects from a mature server framework (Vapor,
Hummingbird, Spring Boot, Phoenix, Rails) that Alula lacks. Five reviewers,
one per area (HTTP, data, background work and messaging, core/operations/CLI,
security), ran against alula 0.36.0, alula-data 0.11.0, hangar 0.9.2 and
alula-cli `main`. Every absence claim below was checked by grep, and the
first four were checked by hand as well. Items this file or DECISIONS.md
already declined are not repeated.

### ✅ Three defects, fixed in alula 0.37.0 / alula-data 0.12.0

The audit set out to list missing features and found three things that were
broken instead. Two of them are this file's opening defect class again: a
check that looked present did nothing.

- **Actuator was built with `init()` in every generated app, since 0.23.0.**
  A defaulted `logger:` made the composer think `ActuatorModule`'s
  composition initializer was unsatisfiable. It fell back silently to
  `init()`, which meant:
  - a private health registry, so readiness always said `UP`;
  - no components on the dashboard;
  - `actuator.format` ignored;
  - the **0.30.0 dashboard role gate never applied**.

  Every Actuator test built the module by hand, the seam the bug was behind.
  Found only by reading the demo's generated composition file. The fix and
  the regression test are in the generator (D46).
- **Readiness lied twice.** Service-owning modules were `running` at
  composition, and nothing changed on `SIGTERM`. They are now `notStarted`
  until their service is entered. A drain service flips readiness to `503`
  first and holds for `lifecycle.drain-seconds` while the transport still
  serves.
- **`DataSourceLiveness` shipped inert.** Its doc said "the surface Alula
  Actuator reads"; nothing read it, so a dead Postgres reported healthy.
  Datasource modules now contribute it as a `HealthCheck`, which readiness
  runs. Verified live: stopping Postgres under the running demo turned
  readiness `503` and left liveness `200`, and restarting it recovered.
- **Cross-site WebSocket hijacking.** A handshake is a `GET`, so CSRF
  exempts it, and CORS does not govern WebSockets, so a cookie-authenticated
  socket was open to any page. `Origin` is now checked by default,
  same-origin.

### Open, ranked by how much an application feels it

| # | Gap | Size | Why it matters |
|---|---|---|---|
| 1 | ✅ *Built 2026-09-24 as alula 0.38.0 / alula-data 0.13.0 (D47); see Docs/queue.md.* ~~**Durable background job queue.**~~ Needs enqueue, retry with backoff, dead-lettering, delay, uniqueness, concurrency limits and status. | L | Three of five reviewers named it first. The scheduler is cron-only, with no persistence and no retries (`Docs/scheduler.md`), and hangar has no `SKIP LOCKED`. Email, webhook delivery and push retries have nothing to stand on; APNs' own docs tell apps to write "a scheduled job that drains a table". |
| 2 | ✅ *Built 2026-09-24 as alula 0.39.0 (D48); see Docs/mail.md.* ~~**Email delivery seam**~~ (`MailDelivery` protocol and an SMTP or provider adapter) | S–M | Blocks sign-in phase 3c: reset, verification, magic links. `OneTimeTokens`' doc example already calls a `mailer` that does not exist. |
| 3 | ✅ *Built 2026-09-24 as alula 0.40.0 (D49); see Docs/http-client.md.* ~~**Outbound HTTP client**~~ | M | APNs, OIDC and JWKS each use `HTTPClient.shared` directly. Nothing shared provides timeouts, retries, a test double or trace-context propagation, so traces stop at the process boundary. |
| 4 | ✅ *Built 2026-09-24 as alula 0.41.0 (D50); see Docs/web.md, Validation.* ~~**Declarative request validation**~~ with aggregated field errors in problem+json | M | Every handler throws one `422` at a time by hand. swift-changeset validates for writes but not for request bodies. |
| 5 | ✅ *Built 2026-09-24 as alula 0.42.0 (D51); see Docs/web.md, Request timeouts.* ~~**Per-route request deadlines**~~ | M | Only idle and header-read timeouts exist. A stuck downstream call holds the handler open indefinitely, and no `503`/`504` comes back. |
| 6 | ✅ *Built 2026-09-24 as alula 0.43.0 (D52); see Docs/openapi.md.* ~~**OpenAPI emission**~~ | L | Cheaper here than anywhere else, because the build plugin already holds the route, parameter and body-type model. |
| 7 | ✅ *Built 2026-09-24 as alula-data 0.14.0; see alula-data Docs/data-postgres.md, Read replicas.* ~~**Read replicas unreachable**~~ from alula-data | M | Hangar routes reads to a replica, but `withRepo` pins one connection and nothing configures a replica. |
| 8 | **Production observability defaults** | S–M | No JSON `LogHandler`, no log level from configuration, and no metrics or tracing backend in the templates. Outbound trace propagation is covered by #3. |
| 9 | **Postgres-only clustering**: LISTEN/NOTIFY PubSub adapter, outbox | M | Running more than one replica requires Valkey today. |
| 10 | **CLI stops at `new` and `migrate`** | M–L | No routes listing, dev watch mode, generators (including the planned `alula generate auth`), app-defined commands or Dockerfile. |

**Smaller, by area** (S unless marked):

- **HTTP:**
  - Responses are JSON only: no `Accept` negotiation and no `406` (M).
  - A `Decodable` body can't be decoded from multipart.
  - No `If-Match` helper for PUT/PATCH, and no pagination envelope or `Link` headers.
  - No idempotency keys (M) and no webhook HMAC verification.
  - TLS certificates can't be reloaded without a restart (M).
  - No WebSocket subprotocol negotiation, compression or server pings.
  - A plain `OPTIONS` answers `405`, not `204`.
- **Data:**
  - No SQLite (L), and `InMemoryDataSource` cannot run queries.
  - Hangar has no JSONB operators, full-text search, bulk upsert or keyset
    pagination. `Pagination.swift`'s doc points at "cursor-based reads below"
    that do not exist.
  - No automatic timestamps, no tracing spans on queries, no seeding, and no
    general distributed lock.
  - No schema-diff migrations, and no Swift code inside migrations.
- **Security:**
  - Authorization is roles and scopes only: no policy or ownership checks (M).
  - No MFA (TOTP planned for phase 5; WebAuthn L).
  - No API-key validator (S–M).
  - mTLS verifies the client certificate but never hands it to the request (M).
  - No first-party JWT or refresh-token issuance (M).
  - No audit trail carrying subject and address.
  - No JSON depth or key-count limits.
  - No breached-password check (belongs with phase 3c).
  - A socket doesn't notice when its session is revoked.
- **Messaging and integrations:**
  - No FCM or Web Push (M each).
  - No object storage or signed URLs (M).
  - No i18n (M).
  - No typed domain events or wildcard topics (M).
  - Channels has no replay of messages sent while a client was disconnected (M).
- **Core:**
  - No optional `@Inject` and no conditional modules (M).
  - No "compose everything, swap one" for tests (M).
  - No start or stop hooks beyond `service`.
  - Actuator has no build-info or env endpoint, and can't change log levels at runtime.

**Deliberately not listed:** everything above marked *deliberate*, and the
HTTP/WebSocket and security items declined in DECISIONS.md: templating,
runtime route registration, a trie router, point-in-time revocation, and
issuing tokens to third parties.

---

## 1. Verification gaps — things CI does not actually check

These come first because everything below is a claim, and a claim CI does not
exercise is a claim nobody has tested since the day it was written.

### ✅ alula-data ran no integration tests *(fixed 2026-08-24)*
Its CI had neither a Postgres nor a Valkey service, so every driver suite
skipped on every push. The drivers are the whole reason the package exists.
Fixed, and the fix immediately surfaced a flaky TTL test that had been passing
only because nobody ran it. The gate itself then failed for a day because it
used bash-only `${!var}` indirect expansion and the Swift image's default
shell for a `run:` step is `sh`. 49 integration tests run in CI now; only the
outage-recovery suite skips, and it has to — it kills and restarts a server,
which a service container cannot do.

### ✅ hangar's CI was two releases stale *(fixed 2026-08-24)*
It still checked `swift-changeset` out as a sibling for a path dependency that
became a URL at v0.1.0, floated on `setup-swift`'s minor version, and passed
`-warnings-as-errors` into dependency compilation. Also 13 macro-fixture tests
were failing and invisible — see below.

### ✅ XCTest failures were hidden behind a green summary *(fixed 2026-08-24)*
`swift test` exits non-zero for either testing library, but its *output* does
not say so in one place: swift-testing prints "Test run with N tests" last,
XCTest prints "Executed N tests, with M failures" earlier. Grepping for the
former hid 13 broken fixtures. `hangar/CI/run-tests.sh` now reports both.
**The same pattern should be applied to `alula` and `alula-data`**, which
still grep for one summary.

### ~~`alula` has no integration tests at all~~ — wrong, struck
I claimed this without checking and it is false. `AlulaTransportTests` binds
real ports: `HTTPWireTests`, `TLSWireTests` and `WebSocketWireTests` connect
over TCP with a raw socket client, including a TLS handshake against a
per-run self-signed certificate. 27 tests, ungated, running in CI today.

Left visible rather than deleted, because three of my claims in this audit's
first draft were about test coverage and two of them were wrong. Check before
believing an entry here.

### ✅ No macOS build anywhere *(fixed 2026-08-25)*
Every package now has a macOS job (`macos-26` for alula and alula-data — see
below; `macos-15` elsewhere). The repos are public, so the 10×
private-repo billing note no longer applies.

Two things had to be learned the hard way: `swift-actions/setup-swift` only
indexes up to 6.2, so the packages declaring tools 6.3 install via `swiftly`
instead — which is also what the toolchain is managed with locally, so CI and
a developer's machine now resolve the same way. And the jobs are build-only
except `alula-cli`'s: macOS runners have no Docker and GitHub service
containers are Linux-only, while these integration suites *fail* rather than
skip without a database. There is no honest way to run them there.

hangar's, swift-changeset's and `alula-cli`'s macOS builds are green.
`alula-cli`'s matters most — Homebrew runs on macOS, so that gap is now
unblocked.

**And the job immediately earned its place** — then spent four releases
describing the wrong cause. It reported that `alula` and `alula-data` could
not build on macOS because `apple/swift-configuration` calls `Data.bytes` in
`FileProvider.swift`, that this was purely upstream, and that
`platforms: [.macOS(.v15)]` was therefore **false today**. Both jobs were
`continue-on-error: true` on that basis.

*(fixed 2026-09-19)* Two blockers were stacked, and neither conclusion held.

The first was ours and was never mentioned: `Duration.nanoseconds(Double)` in
AlulaConfigCore is macOS 26+. It failed *first* — AlulaConfigCore is the
dependency-free half of Config and compiles before swift-configuration is
reached — so the log showed only our error, and the upstream diagnosis above
was written over the top of a failure that had not even been observed yet.

The second is upstream and real, but it is an **SDK** question rather than
something unfixable. `FileProvider.swift` imports FoundationEssentials where it
can and Foundation otherwise; the `macos-15` image gives it the latter, whose
`Data` has no `.bytes`. The `macos-26` image gives it the former.

So the deployment target was never the problem, and `platforms: [.macOS(.v15)]`
was never false. Measured both ways rather than assumed:

| floor | runner | result |
| --- | --- | --- |
| `.macOS(.v26)` | `macos-26` | builds |
| `.macOS(.v15)` | `macos-26` | builds — 5306 steps, 595s |
| `.macOS(.v15)` | `macos-15` | fails in FileProvider |

Both repositories now run the job on `macos-26` with the advisory flag removed,
and the floor untouched at macOS 15. Nothing needed reporting upstream.

---

## 2. Documentation that is wrong or absent

### ✅ `alula/Docs/channels.md` states something untrue *(fixed 2026-08-24)*
> "Security Core is not yet built"

It ships, the demo uses it, and the retroactive `Principal` conformance the
passage predicts is exactly what `Main.swift` now does. A reader takes this as
current.

### ✅ The testing libraries are barely documented *(fixed 2026-08-24)*
`alula/Docs/testing.md` now covers the three sizes of test, and
`Snippets/TestingShapes.swift` compiles every shape it shows — which
immediately caught an `InMemoryCluster(nodes:)` initializer the guide claimed
and that never existed. `AlulaWebTesting` also has a DocC catalogue now.

Original entry:

`AlulaWebTesting`, `AlulaPubSubTesting`, `AlulaChannelsTesting`,
`AlulaCacheTesting`, `AlulaDataTesting` and the new `Components` are each
mentioned in one or two pages in passing. They are what someone reaches for on
day two, and there is no page that says how to test an Alula application.
**Size:** medium. **Highest doc value on the list.**

### ◐ DocC covers 3 of 27 modules — now 13 *(partly closed 2026-08-25)*
Ten new catalogues: `AlulaWeb`, `AlulaChannels`, `AlulaPubSub`,
`AlulaActuator`, `AlulaSecurityCore`, `AlulaWebTesting`,
`AlulaTransport`, `AlulaDataCore`, `AlulaCache`, `AlulaDataPostgres` —
plus `HangarVapor`'s README and hangar's existing catalogue.

The more important half: **nothing was building any of them.** Neither
`alula` nor `alula-data` had a docs job at all, so even the three original
catalogues had never been verified. Both now build every catalogue with
`--warnings-as-errors`, which found real breakage on the first run — an
`OIDCTokenValidator` doc comment linking an internal type, a
`DataSourceError` case link that named a case that does not exist, and a
`ClusteredPubSub` initializer documenting two of its five parameters.

It also caught two pages of *mine* that described APIs incorrectly: a
`Channel.join` that took a payload and threw (it does neither), and
`@Cacheable("prices", ttl: .minutes(5))` (the macro takes `namespace:` and
`Duration` has no `.minutes`). Both were rewritten from the source. That is
the argument for the CI job in one paragraph.

Finished the same night: the protocol and client modules, the testing
helpers, presence, and `alula-data`'s Valkey drivers, its testing
datasource and its migration core. Every catalogue is built in CI. What is
left has no consumer-facing API to document.

---

## 3. Declared gaps, by library

### hangar
- ✅ **No CTEs (`WITH … AS`).** *Closed 2026-08-25.* `with`/`withRecursive`
  define them; `reading(from:)` makes one the query's source, rendered as
  `FROM "cte" AS "entity_table"` so every column reference downstream
  resolves unchanged. Non-recursive bodies can be a typed `Query`; recursive
  ones take a typed anchor and a raw step. `count`, `exists`, `delete` and
  `update` all carry the clause; a bulk write may be *fed* by a CTE but is
  refused if it tries to target one.

  Found while wiring it: `Query.rebinding` — the projection pivot — copied
  every clause except `deletedRows`, so `.withDeleted().select {}` quietly
  went back to hiding deleted rows and `.onlyDeleted()` inverted to mean its
  opposite. Fixed and pinned.
- **No composite-key associations.** `@HasMany`/`@BelongsTo` assume a single
  column. *Medium, and nobody has asked.*
- ✅ **No `EXPLAIN` helper.** *Closed 2026-08-24.*

### ✅ swift-changeset *(both closed 2026-08-25)*
- **Nested changesets.** `nest` attaches children under an association name;
  the parent is invalid while any child is, and child errors surface under
  the path a nested form renders against (`lineItems[2].quantity`). It
  deliberately does not write or decide write order — an insert's children
  need the parent's generated key, so `validatedChanges()` and
  `validatedNestedChanges()` are two calls.
- **Optimistic locking.** `optimisticLock(\.version)` puts the incremented
  value in the `SET` and the value read from the original in the `WHERE`, so
  a driver that has never heard of locking emits the right SQL and matches
  zero rows when someone else got there first. `ValidatedChanges.lock` exists
  only so a driver can raise `ChangesetConflictError` instead of reporting a
  bare row count.

### alula-web
- ✅ **No connection idle/read timeout — a half-open connection is held
  indefinitely.** *Closed in 0.11.0.* Found on 2026-08-26 while building the
  resumable-upload acceptance test: a client that sent request headers with a
  large `Content-Length` and then stopped (or vanished without a FIN) kept its
  connection and its server-side request alive for **~4 minutes**.

  The entry said `HummingbirdCore.ServerConfiguration` "exposes no knob for it
  at all", and that was true of `ServerConfiguration` — but wrong about
  Hummingbird: `HTTP1Channel.Configuration.idleTimeout` has one, and its state
  machine stops the timer once a request is fully read, so it cannot touch a
  long download or an SSE stream. `server.idle-timeout-seconds` drives it,
  60s by default.

  That alone left the purest slowloris case open, and finding out why was the
  interesting part: the upgrade channel installs Hummingbird's idle handler
  from its *not-upgrading completion handler*, which does not run until a head
  has decoded — so a connection that never finishes its first header block is
  invisible to it. Alula adds `RequestHeaderTimeoutHandler` in front of the
  channel for that window, disarming on the header terminator. One setting,
  two mechanisms, and a wire test for each of the four cases.

  This also shortens the resumable-upload recovery the entry mentions: an
  upload interrupted mid-request now releases its per-upload lock in
  `idle-timeout-seconds` rather than ~4 minutes.
- **No HTTP/2 or HTTP/3.** Re-investigated 2026-08-26, and the 08-25 entry
  below needed a correction: it implied the constraint ran deeper than it
  does. What is true on hummingbird 2.26.0 / hummingbird-websocket 2.7.0:
  **HTTP/2 and WebSockets are mutually exclusive on one listener** —
  `HTTPServerBuilder.http2Upgrade` has no WebSocket hook and
  hummingbird-websocket has no RFC 8441 extended CONNECT. Channels are
  WebSockets, so Alula ships HTTP/1.1.

  The correction: **this is Hummingbird's wiring, not the protocol layer's
  capability.** apple/swift-nio-http2 has had RFC 8441 since 1.33.0
  (July 2024, PR #441) — `SETTINGS_ENABLE_CONNECT_PROTOCOL`, the 1→0
  transition rule, `:protocol` pseudo-header validation with the RFC quoted
  inline — and swift-nio-extras converts `:protocol` to swift-http-types'
  `extendedConnectProtocol`. Its issue #92 ("Support extended CONNECT") is
  open only because nobody closed it. Zero Swift server frameworks consume
  the support; the parts are on the shelf, unassembled. Hummingbird's own
  issue (hummingbird-websocket #99, 2025-03) is a maintainer "not possible
  at the moment... I haven't looked into it in any detail", untouched since.

  The landscape moved in mid-2026 and changes the calculus:
  - The Swift **Networking Workgroup** (announced 2026-06) now has Apple,
    Vapor, and Hummingbird converging on `swift-server/swift-http-server`
    (0.1.0, 2026-07): one server with HTTP/1.1 + HTTP/2 + HTTP/3 behind a
    `supportedHTTPVersions` config and an `HTTP3` package trait. Vapor has
    publicly committed to it for H3. Its WebSocket story is in design
    (issue #100) — extended CONNECT is being generalized from
    CONNECT-UDP/datagrams first, WebSockets named as the follow-on.
  - Apple shipped a **pure-Swift QUIC + HTTP/3 stack for Linux**
    (swift-nio-quic / swift-nio-http3, 0.2.x). Not usable yet: prerelease,
    all-SPI ("no support guarantees"), requires a beta swift-crypto env var,
    no mTLS or keylog, and absent from the QUIC Interop Runner — four
    independent not-ready signals. Terminate HTTP/3 at a proxy (Caddy/nginx)
    until those clear; revisit in two quarters.

  The plan, decided 2026-08-26:
  1. **0.4.0 generalized the upgrade seam** (`UpgradeResponse` is a
     discriminated enum, `RouteRegistration.Kind.upgrade(UpgradeKind)`), so
     an HTTP/2 transport serves every existing WebSocket handler unmodified
     — RFC 6455 vs RFC 8441 differ only below `WebSocketConnection` — and
     WebTransport lands later as an additive case, not an API break.
  2. When transport work starts, it is a **second** transport behind
     `ServerTransport` (the seam exists for exactly this), either adopting
     swift-http-server early — the leaning, since that is where the
     ecosystem is converging and Alula has the concrete WebSocket need to
     push its design — or ~1,000 lines of direct NIO wiring over
     NIOHTTP1/NIOHTTP2/NIOWebSocket, which would make Alula the first
     Swift framework serving WebSockets over HTTP/2.
  3. Prerequisite before investing: verify RFC 8441 *client* support in
     practice (Safari and common intermediaries especially). If browsers
     mostly fall back to HTTP/1.1, this drops in priority regardless.

  *The seam work is done; the transport is a bounded project awaiting the
  client-support check and the swift-http-server WebSocket design.*
- No templating or SSR. *Deliberate; out of scope.*
- No runtime route-registration API beyond the bootstrap escape hatch.
  *Deliberate.*

### alula-actuator
- ~~**No authenticated production access.**~~ **Wrong — struck.** I read a
  stale passage in `Docs/actuator.md` rather than the code. `ActuatorExposure`
  already has three levels, and `health_only` is the *default* outside
  development precisely so an orchestrator has a probe. The doc contradicted
  itself and has been fixed.
  ~~What remains, and it is small: the `full` dashboard is unauthenticated
  wherever it is enabled, so running it in production needs something in
  front. That is now stated in the doc rather than implied. *Small.*~~
  **Closed in 0.30.0:** `actuator.dashboard-pipelines` and
  `actuator.dashboard-roles` put the dashboard behind the `authenticated`
  lane and a role check; health stays open.
- No live-updating dashboard, no historical metrics. *Deliberate.*

### alula-presence
- ✅ **The gossip trust model.** *Decided and documented in 0.11.0.* The entry
  asked two questions — what happens when a malicious or buggy node gossips bad
  state, and what the rolling-upgrade story is across protocol versions — and
  said a threat-model decision had to come before any code. The decision:

  **The PubSub bus is the trust boundary.** Gossip rides one reserved topic, so
  anything that can publish to it can assert presence state, and nothing
  authenticates a frame. That is Phoenix Presence's posture over Redis too, and
  it is the right one for the deployment this targets: a broker inside your
  network. It is now *stated* rather than assumed, because the consequence
  deserves to be explicit — an attacker who can publish to your broker can
  forge presence, and can do considerably worse to everything else on the same
  bus. Presence is not what to harden first in that situation.

  Frame authentication (a shared secret, an HMAC per frame) was considered and
  not taken: it moves key distribution and rotation onto the operator to defend
  a boundary the rest of the stack does not defend either. Revisit it if a
  deployment ever shares a broker across trust domains.

  Within that boundary, **buggy** peers and version skew are bounded, by rules
  no correct sender ever violates: a frame asserting a third replica's entries
  is dropped, a frame over `max-entries-per-frame` (10,000) is dropped, a frame
  claiming this replica's own dots has those claims stripped (0.10.0 — that one
  was a one-frame remote process kill, not mere corruption), and a frame with
  an unrecognised wire version is dropped rather than guessed at.

  **Rolling upgrades:** a version bump partitions the cluster's presence for
  the duration of the roll — each half sees the other's replicas as silent and,
  in degraded mode, hides their entries after `down-after`. A visible partition
  beats two versions agreeing on the bytes and disagreeing on the meaning. Both
  halves of the trade are written down in `Docs/presence.md`.

### alula-data / drivers
- No cross-database abstraction, no auto-migration at boot, no query caching.
  *All deliberate.*
- `AlulaDataValkey` has no PubSub and no transaction support. *Deliberate —
  Valkey is not transactional in that sense.*

### alula-channels-js
- Published to a repo, **not to npm**. Blocked on the org being public.
- No CI badge, no bundled build; consumers use it as ESM source. *Fine for now.*

---

## 4. Product gaps — things that would decide adoption

### ✅ A Vapor shim for hangar *(published; closed 2026-09-18)*
`hangar-vapor` exists at `Hangar/hangar-vapor`, committed locally: three
pieces and nothing else — `app.hangar.use(config)` owns the pool's lifetime,
`req.hangar` is a `Repo` carrying the request's logger, and
`req.transaction { }` runs on one connection and binds `Repo.current` so a
service type can join without every signature threading a repo through. Nine
integration tests against a real pool in a real application, gated so they
cannot skip; `Snippets/ReadmeShapes.swift` compiles every example the README
shows.

`req.hangar` deliberately does *not* pin a connection for the request's
lifetime — a handler awaiting an HTTP call between two queries should not be
holding one.

~~**Blocked on two decisions of yours:** a hangar v0.2.0 tag, and creating the
public repository.~~ Both done: hangar is tagged through v0.6.0 and
`hangar-vapor` is published at `Alula-Framework/hangar-vapor`.

### ✅ A contributor test script *(done 2026-08-24/25)*
`./scripts/test.sh` in hangar, alula-data and hangar-vapor: starts throwaway
containers, runs everything through `CI/run-tests.sh`, tears them down.

alula-data's waited for Postgres and then started the suite, leaving Valkey
to race the Swift build. It usually won — which is how a suite becomes
intermittently red for reasons nobody can reproduce. It waits for both now.

### ✅ `alula new --with` flags *(done 2026-08-24)*

---

## 5. Known-and-accepted

Recorded so they are not rediscovered as bugs:

- **Format debt**, measured 2026-09-18: `alula` **1,725** and `alula-data`
  **1,064** violations against the shared `.swift-format`; `alula-cli` is
  **0** and blocking. Both of the others' lint jobs are advisory, and alula's
  has grown — this entry said 1,309 and `ci.yml` said ~1,240, two stale numbers
  that disagreed with each other and with the tool. A bulk reformat must avoid the macro fixture files,
  whose expected-expansion strings a careless regex corrupts.
- **The tutorial checkpoint runner had been red since it landed** — 6 of 9,
  and it took two fixes. All three failures were `curl: command not found`;
  the Swift images carry neither python3 nor curl, and only python3 was
  installed. That took it to 8 of 9. The last one was a real race the
  tutorial teaches: the checkpoint backgrounds `swift run App` and curls it
  on the next line, so a reader copying the block gets connection refused
  while the server is still binding. Now waits on `/actuator/health` with a
  bounded `curl --retry-connrefused`.

  Then cp06 and cp08 showed red — and they had **never** been passing
  legitimately. The application reads its database URL from `alula.yaml`
  (`127.0.0.1:55432`, hardcoded in the tutorial on purpose so a starter
  project does not fight a local 5432); CI's Postgres is a service container
  elsewhere. The runner rewrote `$ALULA_DATABASE_URL`, which is the
  *migrate CLI's* variable and one the application never reads — a split the
  tutorial documents and the runner did not honour.

  So the app died on connection refused every run. Those checkpoints looked
  green because their curls were racing a socket that exists for a few
  milliseconds: the transport binds 8080 and logs "listening" *before* the
  pool gives up, so an immediate request sometimes landed. Adding the health
  check removed the race, and the pre-existing failure became visible —
  which is what a health check is for. The runner now rewrites both sources.

  Fixed along the way, though it turned out **not** to be the cause of the
  above: cleanup used `pkill -f "$work"`, which can never match, because the
  server appears in `ps` as a relative path with the work directory nowhere
  in its command line. Any checkpoint failing before its `kill %1` leaked a
  server holding port 8080. I hit that myself — the sabotage run I used to
  test the cp03 fix leaked a server that broke every local run for an hour.
  Blocks now run under `setsid` and cleanup kills the process group.

  All fixed 2026-08-25; 9 of 9 pass. Recorded because every one of these was
  misattributed on first read: the first *looked* like "the tutorial is
  broken" and was "the image is thin"; the second looked like CI flakiness
  and was a defect in the documentation; the third looked like a leaked
  process and was a config source nobody was patching. I guessed wrong twice
  on that last one before the crash fix below made the app say what was
  actually wrong.

### ✅ A generated app crashed instead of failing to start *(fixed 2026-08-25)*
Found while chasing the above, worse than the thing I was chasing, and the
reason the thing I was chasing became solvable — two rounds went to guessing
because the app's only output was a register dump. When
bootstrap failed, a generated app died with `Fatal error: Error raised at
top level`, a register dump, thread backtraces and a loaded-image list —
because the template's `main` was `async throws` and the Swift runtime traps
on an error that escapes it.

The two failures a first project actually hits are Postgres not running and
port 8080 already bound. Neither is a crash; both were reported as one. All
three templates now catch, print one line, and exit 1 — verified on real
generated projects for both cases.

~~**Still open:** the same fix belongs in `AlulaCore` as a `Alula.main`
helper.~~ **Closed** — `Alula.run(configuration:modules:composedBy:)` is that
helper: it prints why and exits 1 rather than trapping out of a throwing
`main`, and hand-written applications get it on the same terms as generated
ones. The "blocked on an alula release, templates pin 0.1.2" note is eighteen
releases stale; templates pin 0.20.0.
- **One unexplained test failure**, alula-data, 2026-08-25: a single issue
  in a 375-test run that did not reproduce in ten subsequent runs, cold
  containers included. The Valkey readiness gap was fixed because it was
  genuinely there, not because it was shown to be the cause. Recorded so the
  next occurrence is the second one rather than the first.
- **Root builds need `--enable-all-traits`.** A root build compiles every
  target regardless of traits, so a plain `swift build` in `alula` or
  `alula-data` fails by design. Documented in both READMEs.
- **Relative paths remain in git history.** Not sensitive; removing them would
  mean rewriting three more repositories and moving four tags for no security
  benefit.
- **Old per-package repos are archived**, with notices pointing at their
  replacements.
- ✅ **A bound transaction scope pins a connection for the scope's whole life.**
  *Closed by the composition migration.* `withPostgresTransactions(in:)`
  resolved the scope's `Repo` eagerly, to bind Hangar's ambient repo, and
  resolving a `Repo` checked a connection out of the pool. For an ordinary
  request that was the intended model — a request holds a connection while it
  runs. For a **WebSocket upgrade it was a leak**: an upgraded request's
  `Scope` lives as long as the socket, so every open browser tab held a
  Postgres connection until it closed, and a pool of ten served ten tabs and
  then nothing.

  Found dogfooding, 2026-08-25, as `PostgresConnection deinitialized before
  being closed` at the end of a test run — a message about a connection rather
  than about the scope that never let go of it.

  The entry proposed making the ambient-repo binding lazy. What shipped
  instead removed the binding: `@Transactional`, `withPostgresScope`,
  `withPostgresTransactions` and the transaction coordinators are gone, a
  repository holds the pool as a singleton, and `withRepo` leases a
  connection for one operation and returns it. A scope pins nothing, so
  neither an upgrade nor a handler that never queries can hold a connection
  open. See `COMPOSITION-MIGRATION.md` §2.3 (untracked, local to this
  working copy).
- ✅ **Alula Web has no static-file handling.** *Closed.* Static assets ship
  with exactly what this entry asked for and more (the closure text named
  `container.assets(at:root:)`, which went with the container in 0.17.0; assets
  are declared as module values now): containment by resolving
  the path and comparing against the root rather than pattern-matching for
  `..`, directories refused, an extension→content-type table, per-pattern
  cache rules, an SPA fallback gated on `Accept`, content hashing, and
  `Accept-Encoding` negotiation against precompressed siblings. Range
  requests and ETags — "the obvious next layer" — are there too, as
  `serveContent`'s RFC 9110 conditional/range engine over a `ByteSource`.
