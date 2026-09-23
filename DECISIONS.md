# Decisions taken without asking

Judgement calls made while executing `COMPOSITION-MIGRATION.md`'s work plan,
each with the alternatives it was chosen over and what reversing it costs.
Newest first. Nothing here is load-bearing on agreement — if a call reads
wrong, say so and it changes.

---

## D42 — Telemetry: typed events in the core, reporting as a module, and where it departs from the spec

**Context.** The swift-telemetry design spec (typed events after Elixir's
`:telemetry`; spans; metric definitions; bridges; testing capture;
performance targets) was to be brought into Flight "in the most library
cohesive way", maximizing performance, developer experience and
ergonomics.

**Chosen — placement.** One package, as everything else is. The spec's
eight targets become three products and a macro plugin:

- `FlightTelemetry` holds events, emit, spans, handlers, metric definitions
  and the macros.
- `FlightTelemetryTesting` holds capture.
- `FlightTelemetryBridges` holds the swift-metrics reporter, the tracing
  observer, the log bridge and `FlightTelemetryModule`.

The core depends on swift-service-context alone and is **ungated**, so any
target, FlightCore's lean ones included, can emit. That moves the lean
consumer from 7 resolved packages to 8, because SwiftPM resolves by
package, not product. The alternative, gating the core behind a trait,
would have left FlightSessions, FlightRateLimit and FlightScheduler unable
to emit. The bridges sit behind a new `Telemetry` trait, which `Web` and
`APNS` imply. Both already bring swift-metrics and tracing, so neither
resolves anything new.

**Chosen — adoption.** Flight's own subsystems are the first emitters. The
0.33 counters became events (`SessionEvents`, `SignInEvents`,
`APNSEvents`), plus `HTTPEvents.RequestHandled` from dispatch: an event,
not a span, because the request is already a tracing span. Each module
contributes default metric definitions under the exact 0.33 names, through
the D15 aggregate, so a package Flight has never heard of does it the same
way. The `metrics:` factory parameters from 0.33 are gone; tests capture
events instead.

`FlightTelemetryModule` is a `dependencies` entry of the Web, Sessions,
Security and APNs modules ("naming one module names its stack"). Reporting
is **on when a backend is bootstrapped**: metrics when `MetricsSystem` is
not the no-op, tracing when `InstrumentationSystem` is not. Without this,
an app upgrading from 0.33 with Prometheus bootstrapped would silently lose
every Flight series. With it, an app with no backend attaches nothing and
pays nothing.

**Departures from the spec, each for a reason.**

1. **`SpanHandle` is `~Copyable`, not `~Escapable`.** The spec
   pre-authorized this fallback, and asked for a reproducer. On Swift
   6.3.3, `struct H: ~Copyable, ~Escapable { @_lifetime(immortal) init() {} }`
   fails with "an initializer cannot return a ~Escapable result", and
   `@_lifetime` needs the experimental `Lifetimes` feature.
2. **`EventContext` is a lazy, noncopyable view, like `AnyEvent`.** The
   spec reads the clock and `ServiceContext.current` once per emit. Measured
   here, that is 15 ns plus 13 ns of a 40 ns budget, on every emit, for
   values a metrics handler never reads. Each value is now read on first
   access and shared by every later handler. `snapshot()` keeps a copy. The
   timestamp is "first read", which is also "at the emit" whenever handlers
   keep the O(1) contract.
3. **Metric definitions are static members (`.counter(…)`), not
   `Counter(…)` types, and the builder is `TelemetryMetric.all { }`, not
   `Metrics { }`.** swift-metrics already has a `Counter` type and a
   `Metrics` module, and an application imports both. The spec's
   `MetricsReporter` protocol became `MetricRecorder`, one per definition,
   and `SwiftMetricsReporter.attach` returns `HandlerTokens`.
4. **A span's `start` measurement is `monotonicTime: Duration`** since a
   process reference. `ContinuousClock.Instant` is not a measurement.
5. **`expectNoEmission` throws** rather than asserting. Flight's testing
   modules import no test framework, and a thrown error fails a test under
   any framework.
6. **No `Poller`.** A `@Scheduled` job that emits is one. `@Instrumented`
   stays deferred, as the spec's open questions allow.
7. **Field names are snake_cased** from property names. This is what every
   backend expects of a label.

**Chosen — the hot path, after the spec's default failed.** The spec's
default was a mutex snapshot per emit, to be switched only if the 40 ns
target failed. It failed at 233 ns. The components, measured on this
machine:

| Component | Cost |
| --- | --- |
| mutex lock plus array retain | 36 ns |
| per-handler in-flight atomics | 15.5 ns |
| clock | 15 ns |
| task-local | 13 ns |
| seven pthread-key calls | ~12 ns |

On top of those, the dispatch generic ran unspecialized across the module
boundary. The replacements:

- **One flags word per slot.** It says whether typed handlers exist, and
  whether any erased handler or span observer exists anywhere; the registry
  keeps the last two bits current on every enrolled slot. Nothing attached
  is then one load.
- **A span-level flags word** (`_spanFlags`, written by the macro), so an
  unobserved span is one load, not five.
- **RCU for typed handlers.** An emit announces itself in one of two epoch
  counters and reads the published list without a lock. Attach and detach
  swap the list and wait out a two-flip grace period before freeing the
  old one. That wait is the detach guarantee, so typed handlers need no
  per-handler atomics.
- **An `@inlinable` typed dispatch**, so handlers are called specialized.
  The spec limits `@inlinable` to the emit path, and this is the emit path.
- **One thread-state pointer** instead of seven pthread-key calls.

Erased handlers keep the per-entry Dekker check, because they are cached on
every slot they match and cannot be swapped out of all of them at once.

The result, measured by `Benchmarks/`:

| Scenario | Measured | Target |
| --- | --- | --- |
| emit, nothing attached | 1.7 ns | ≤2 |
| span, nothing attached | 1.8 ns | ≤5 |
| emit, one typed handler | 23 ns | ≤40 |
| emit, one erased handler | 53 ns | ≤80 |

All four make zero allocations.

**Refined — the detach guarantee.** `detach()` returning means the handler
is never called again. A detach from *inside* a handler now does not wait,
and takes effect for emits that start after it. Waiting there was a latent
deadlock: two threads each detaching the other's handler wait on each other
forever. That hazard existed before this redesign too.

**Found — ThreadSanitizer cannot see `Synchronization.Mutex` on Linux.** A
reproducer on Swift 6.3.3: four threads appending to an array only inside
`Mutex.withLock` produce "Swift access race". The lock and unlock live in
the uninstrumented standard library and hand off through a futex. A TSan
gate that reports every contended lock is no gate, so telemetry locks with
a `package` `Lock` over `pthread_mutex_t`, which TSan intercepts. That is
this package's one `@unchecked Sendable`, justified at the declaration.

Its state is never `Void`: a zero-sized field shares its address with the
lock's own storage, and TSan reports the overlap as a race.

**CI.**

- **ThreadSanitizer job.** The telemetry suite runs with the 5 s stress
  test, and any report fails the job.
- **`check-telemetry-compile-errors.sh`.** It pins the refusals: a string
  measurement, a non-tag tag, another event's tag or field, a bad name. It
  also builds a positive control, so a refusal proves something.
- **Benchmarks job.** It enforces zero allocations on every push. It prints
  latency but doesn't enforce it, because a shared runner cannot hold a
  2 ns line. The latency gate is `swift run -c release TelemetryBenchmarks`
  on a quiet machine before tagging, which exits non-zero on a miss.

**Found on the way.**

- **The composition generator's imports.** It never imported the Swift
  module of a module included only through another's `dependencies`. It was
  latent until `FlightTelemetryModule` became the first such module, and
  wiring the demo found it; `composerImportsDependencyModules` pins it.
- **A capture double-counting.** A prefix capture counted events twice when
  a broader capture elsewhere was live, because each shared erased handler
  delivered to every current sink. `overlappingPrefixes` pins that.

**Alternatives.**

- **A separate swift-telemetry package**, as the spec's layout assumes.
  One package is how every other Flight subsystem ships. The core depends
  only on swift-service-context and swift-syntax, so extracting it later is
  mechanical. That becomes the right call when Hangar adopts telemetry and
  must stay light: it should not resolve Flight to emit.
- **Keep the 0.33 counters and add events beside them.** Two mechanisms
  for one fact, and the counters could not be captured in a test, traced
  or logged.
- **Opt-in `FlightTelemetryModule`.** This silently drops 0.33's series on
  upgrade, as described under adoption.

**Cost of reversing.**

- **Placement:** extracting the core is mechanical.
- **Adoption:** reversing it means restoring direct counters in three
  subsystems.
- **Hot path:** the RCU list is self-contained in `HandlerSlot`; a mutex
  could return in an afternoon, at 4–10× the cost per emit.

---

## D41 — Answering the 0.32 security review: what changed, and the one thing that did not

**Context.** An independent review of the security stack found no P0. It
made eight findings. Each was checked before acting: NIST SP 800-63B-4 and
OIDC Core were read directly, and every code claim was read against the
source. All eight held.

**Changed.**
1. **Absolute authenticated lifetime** (P1). Stored as a sign-in timestamp
   in the session, checked by `Authentication`, and configured in
   `sessions.*` because `FlightSecurityModule` already takes the session
   runtime. No signature changed. Legacy sign-ins are grandfathered with a
   stamp rather than all signed out at upgrade.
2. **NFC** (P1). The fallback to the legacy form is a second Argon2
   verification, which only a real account would pay. That's a timing
   signal the review didn't mention, so the unknown-account path pays it
   too.
3. **UserInfo** (P1). The review's sequence was followed exactly, including
   an exact `sub` match. A failing UserInfo fails the sign-in rather than
   degrading to ID-token claims, because an application may be making
   authorization decisions on `email_verified`.
4. **APNs invalidation** (P2) was more serious than rated. Following the old
   guide, a sandbox/production mix-up would have deleted every stored
   device token, because `BadDeviceToken` is what every token returns then.
   The new API never deletes on misconfiguration-shaped answers.
5. **Retry advice** (P2), **`__Host-`** (P3, opt-in: automatic would rename
   the cookie and sign everyone out), and **metrics** (P3, swift-metrics,
   closed-set dimensions, injectable factories).

**Not changed: revocation stays point-in-time** (P1/P2). The review allowed
documenting this as the minimum. The stronger model is a per-account
version stamped into every session and checked on every authenticated
request. That's a store read per request, forever, to close a window of
milliseconds around a rare operation. With the new absolute lifetime
bounding whatever slips through, the cost isn't justified as a default.
The guarantee is now stated where it's used, with the ordering that keeps
the window to one in-flight sign-in.

**Not done: independent hostile review.** The review's closing advice was
that a second adversarial reviewer is now worth more than more features.
That's not something code can do. It's recorded here, and in the release
notes, as the recommended next step.

---

## D40 — Sign-out-everywhere is a store capability; one-time tokens store digests beside sessions

**Context.** Flows the sign-in work leads to need two primitives. A password
change should end a person's other sessions. A reset or verification link
must work exactly once. Neither existed.

**Chosen, revocation.** A session gets an `owner`, which `Session.signIn`
sets to the subject. The middleware hands the owner to a store that adopts
a new `OwnerIndexedSessionStore` protocol, and
`SessionRuntime.revokeSessions(ownedBy:keeping:)` deletes by owner.
Adopting it is a *capability*, not a new requirement on `SessionStore`:
stores receive opaque bytes, and adding a requirement would break every
third-party store for a feature many applications never use. A store that
doesn't adopt it throws `SessionRevocationUnsupported` when asked, rather
than ending nothing. An owner-less record encodes byte-identically to
before, so existing sessions and the "same bytes, no write" optimisation
are untouched.

**Chosen, one-time tokens.** `OneTimeTokens` in FlightSecurityCore: 256
random bits, SHA-256 digest as the store key, purpose-bound, redeemed by an
atomic `take`, optionally bound to a value (a password hash) whose change
voids the token. The store seam, `OneTimeTokenStore`, lives in
dependency-free `FlightSessions` rather than beside the tokens. The reason
is packaging, not taste. flight-data depends on flight with no traits, so a
seam inside Security-gated `FlightSecurityCore` would force the Security
trait's dependencies on every flight-data user just to ship a Valkey
implementation.

**Point-in-time, stated (0.33.0).** Revocation ends the sessions that exist
when it runs. A sign-in that verified the old password just before a change
can save its session just after the scan and survive. An independent review
asked for the guarantee to be named rather than implied. It is named now,
in the API docs and `Docs/sessions.md`, with the ordering that keeps the
window to one in-flight sign-in (change the credential, then revoke). The
authenticated lifetime added in 0.33.0 bounds anything that slips through.
The linearizable alternative is a per-account version stamped into every
session and checked on every authenticated request. That costs a store
read per request forever, to close a window of milliseconds on a rare
operation. It isn't the default, and an application that needs it can
build it on `CredentialStore` without anything here changing.

**Why binding rather than an index.** "Void all outstanding reset links"
could be an index by subject, like sessions. Binding to the password hash
gets the same result with no index, catches password changes made any other
way, and needs nothing from the store beyond `put` and `take`.

**Alternatives.** A per-subject "sessions valid after" timestamp checked on
every request (works with any store, but costs a store read per
authenticated request forever, to serve a rare operation). Storing tokens
raw (a leaked store would be a pile of working reset links). Get-then-delete
redemption (a race redeems one link twice; the test has twenty requests
race). A token-store seam in FlightSecurityCore (the packaging problem
above).

**Cost of reversing.** Everything is additive. `SessionRecord.owner` is
optional and omitted when nil.

---

## D39 — First-party sign-in, behind a seam an external provider also fits

**Context.** "No first-party credential checking" was a stated non-goal:
authentication was federated to an identity provider, and Flight validated
the tokens it issued. The user reversed it on purpose. An application should
be able to start on its own accounts without running Keycloak, and switch to
one later without rewriting its sign-in. Neither Vapor nor Hummingbird ships
more than building blocks here (bcrypt, authenticator protocols, session
login), so this goes past parity rather than catching up.

**Chosen.** A `SignInProvider` protocol answering two questions every
provider can answer. Starting: `.form(fields)` or `.redirect(URL)`.
Finishing: a `Principal`. It has two implementations, built together:
`PasswordSignIn` over an application-implemented `CredentialStore`, and
`OIDCSignIn` using the authorization code with PKCE against any provider.
Each ships as a module providing `signInProvider: any SignInProvider`, so the
switch is one line in `modules:` and listing both is a build error. Several
calls inside that:

1. **Four standard claims are the vocabulary** (`email`, `email_verified`,
   `name`, `preferred_username`: OIDC Core §5.1). The password provider emits
   them under the same names, and `Principal`'s session encoding now keeps
   them where it used to drop every claim. Without that, a principal from a
   cookie had no `email` while the same person arriving by token did, and
   every screen showing who is signed in would have to know which path
   produced it.
2. **The credential store is not a user model.** It asks for two operations:
   find by identifier, and save a stronger hash. The application's table
   stays its own, which is the storage-agnostic shape Hummingbird chose, not
   Vapor's, which is tied to its ORM.
3. **The authenticator owns the invariants.** It throttles per identifier and
   per address before hashing, runs a dummy verification for unknown accounts,
   gives one answer for every wrong guess, reports a disabled account only
   after its password verifies, normalizes passwords, and rehashes at
   sign-in. *(Corrected in 0.33.0: this shipped with NFKC and called it
   SP 800-63B's recommendation, which it was in revision 3. SP 800-63B-4
   says NFC. New hashes use NFC, and an NFKC-form hash is verified and then
   rehashed on its owner's next sign-in. An independent review caught it.)*
4. **The sign-in throttle fails closed**, the reverse of the `RateLimiting`
   middleware's D33. That middleware protects capacity, where an outage
   letting traffic through is the lesser harm. This one is the brute-force
   defence, and a limiter outage is exactly when nothing else would notice a
   flood.
5. **`FlightSecurityModule`'s validator became optional** when sessions are
   present, with a stand-in that turns any presented bearer token into an
   invalid credential. Otherwise a sessions-only application had to invent a
   validator it never used. With neither a validator nor sessions,
   composition still stops.
6. **OIDC keeps no tokens.** The ID token establishes who signed in, once.
   An access token for calling APIs as the user is a different feature. Sign-out
   is RP-initiated by `client_id`, since no `id_token_hint` is kept.
7. **Proven against the real thing.** A contract test runs one controller
   through both providers and requires identical `/me` answers. A CI job runs
   the OIDC provider against a real Keycloak, driving its actual login form,
   because a seam with one implementation is a guess about its interface.

**Alternatives.** Protocols first with implementations later (rejected: an
interface nobody has implemented twice is speculation). Tying the store to
flight-data's persistence (rejected: most applications already have a users
table). A generic `claims: [String: Any]` pass-through in the session
(rejected: it was dropped on purpose, and the standard four are the ones
that describe a person rather than a token). The password grant (ROPC) to
talk to an external provider with the same form (rejected: OAuth 2.1 removes
it, and it would teach applications to handle passwords a provider should).
Failing the sign-in throttle open like the middleware (rejected above).

**Cost of reversing.** The seam and both providers are additive. Reverting
the session encoding would drop the standard claims from session principals
again. Reverting the optional validator is source-compatible for every
caller that passes one.

---

## D38 — Security headers are a dispatch policy with three defaults on, not a middleware

**Context.** The September gap audit listed security headers and left them
unbuilt only because they were not picked. The obvious shape was a
middleware, three `settingHeader` calls.

**Chosen.** A `SecurityHeaders` value on `WebRuntime`, read by
`FlightWebModule` from `web.security-headers.*` and applied by Dispatch to
every response after the whole chain has run. `nosniff`, `DENY` and
`strict-origin-when-cross-origin` are on by default; HSTS and CSP are off
until configured. A header already on the response wins.

**Why not a middleware.** Dispatch routes first and then runs the matched
route's lanes, so `.default` never runs for a route naming
`pipelines: [.authenticated]` — the trap `CORS`'s documentation already
spells out. A missing CORS header breaks a page visibly. A missing security
header breaks nothing visibly, and it would go missing on precisely the
signed-in routes, which are the ones that most want framing refused. A
policy the envelope applies cannot be dropped by a lane choice.

**Why these defaults.** The three on by default are what Helmet and most
framework defaults send, and each is wrong only for a service that knows
it: one framed by another origin on purpose, which says so in one line of
configuration or one header on the route. HSTS is off because it cannot be
recalled — a browser holds it for `max-age` whatever the server says later,
and `includeSubDomains` from the wrong host locks a whole parent domain out
of plain HTTP. CSP is off because no default is both useful and harmless.
`X-XSS-Protection` is not sent at all: browsers removed the auditor it
controlled, and `1; mode=block` is now at best inert.

**Alternatives.** A `SecurityHeaders` middleware plus documentation telling
people to list it in every lane (the CORS approach — acceptable for CORS,
whose failure is loud). Everything default-off (a framework whose secure
behaviour is opt-in is one most applications never opt into). HSTS on by
default as Helmet does (the one header whose mistake cannot be undone;
that belongs to an operator). Overriding a route's own header (a route
that means to be framed would have no way to say so).

**Cost of reversing.** Defaults are one initializer; the application point
is one line in `DispatchBuilder.makeDispatch`. Turning the defaults off
would be a behaviour change applications would have to be told about, the
same way turning them on is.

---

## D37 — The Argon2 dependency is vendored, not depended on: a revision pin poisoned resolution

**Context.** Wiring password hashing into a real downstream consumer — the
`flight-cli` demo template, adding `Security` to its trait list the way any
application would — failed at `swift package resolve`, not at build:

```
error: Dependencies could not be resolved because root depends on 'flight' 0.29.0..<1.0.0.
'flight' >= 0.29.0 cannot be used because no versions of 'flight' match the
requirement 0.29.1..<1.0.0 and package 'flight' is required using a
stable-version but 'flight' depends on an unstable-version package
'phc-winner-argon2'.
```

Reproduced in isolation, outside the demo's larger dependency graph, with
nothing but a `.package(url: flight, from: "0.29.0", traits: ["Security"])`
and one product dependency. SwiftPM's rule: a package resolved by a version
requirement (`from:`, `exact:`, a range) may not depend, even transitively
and even behind a trait, on one resolved by `revision:` or `.branch(_:)` —
"stable" and "unstable" requirements cannot mix in one resolution unless
the *root* manifest is itself on an unstable requirement. D35's `revision:`
pin on `phc-winner-argon2` — chosen because that repository carries no
semver tags — made every one of Flight's own tagged releases with
`Security` enabled (0.28.0 and 0.29.0, both already public) unresolvable
by any consumer depending on Flight the ordinary way. `check-lean-consumer.sh`
never caught it: it proves a *lean* (`traits: []`) consumer stays lean, and
never resolves a `Security`-trait consumer at all, let alone one using
`from:` rather than a path dependency.

**Chosen.** Vendor the same six files D35 already identified as the whole
of what upstream's own `Package.swift` builds — `argon2.c`, `core.c`,
`encoding.c`, `ref.c`, `thread.c`, `blake2/blake2b.c`, plus the headers
those need — into `Sources/Security/CArgon2`, as an ordinary SwiftPM
`.target`, no `systemLibrary` (Argon2 is not preinstalled anywhere the way
zlib is, which is why D35 rejected this shape originally) and no external
package dependency at all. `NOTICE.md` in that directory names the exact
commit (the same one D35 pinned) and the update procedure. This removes
the non-version requirement from the graph entirely — there is nothing
left for a consumer's `from:` to conflict with.

**Why this does not reverse "no hand-rolled cryptography."** Same answer
D35 already gave: the source is copied verbatim, not written or modified.
Vendoring changes where the bytes live, not who wrote them or what they
compile to.

**Why D35's stated reason to reject vendoring no longer holds.** D35's
objection was owning "the update cadence of someone else's cryptographic
C source" — true in the abstract, but the actual cost turned out to be
fixed and small: six files that have not needed a change since 2021 (the
RFC they implement finalized then), a `revision:` line to bump in one
place (`NOTICE.md`) if that ever changes, and no exposure to upstream
publishing a bad tag or moving a branch out from under a pinned commit —
a risk a `revision:` pin does not actually carry but a looser reference
would. Weighed against a dependency shape that breaks resolution for every
downstream consumer, on every tagged release, indefinitely, the update
burden is the smaller cost by a wide margin.

**Alternatives.** Leaving the `revision:` pin and telling consumers to
depend on Flight with `revision:` too (rejected: forces every application
using `Security` into an unversioned dependency on Flight itself, visible
only after a resolution failure with no obvious cause — precisely what
broke the demo). A `.branch(_:)` reference instead of `.revision(_:)`
(rejected: SwiftPM classifies both as non-version requirements identically;
verified, not assumed, before ruling it out). Asking upstream to cut a
semver tag (no channel to request it, and this needed fixing now, not
contingent on a third party's release cadence). Switching to a different
Argon2 package with real semver tags (searched again at this decision; the
landscape D35 already surveyed had not changed).

**Cost of reversing.** `Sources/Security/CArgon2` and the two `.target`
references to it in `Package.swift`; `Argon2idHashing.swift`'s `import
CArgon2` is the only source file that would need to change.

---

## D36 — CSRF checks a header only, and a request with no session is not an error

**Context.** Sessions' own doc has said since 0.23.0 that CSRF is "the next
thing to build on this," deliberately left open because it needed the
session abstraction that did not exist yet. It does now.

**Chosen.** The synchronizer pattern: one token per session, generated on
first access and stored in `Session` itself rather than a second cookie —
no double-submit cookie, and none of the subdomain-cookie-injection
surface that pattern carries. `CSRFProtection` compares
`X-CSRF-Token` against it, constant-time, on every method RFC 9110 does
not call safe. Two narrower calls inside that:

1. **Only the header is read, never a submitted form field.** The defense
   CSRF protection provides is that a script on an attacker's origin
   cannot read a value off the defender's page to attach it — the Same-
   Origin Policy is the whole mechanism, and requiring a header a script
   would have to deliberately set already proves that, whichever channel
   handed the token to the legitimate client in the first place. Parsing a
   form body for the same value is more code checking the identical
   property a second way.
2. **A request with no session is left alone, not refused.** CSRF exists to
   protect ambient authority a cookie carries automatically; a route with
   no `Sessions` in its lane — a bearer-token API, most commonly — has none
   of that to protect, the same reason such routes are already immune in
   the literature this defends against. Refusing them would force every
   non-cookie route in an application to carry `Sessions` just to compose.

**Why `SessionReading` still matters given (2).** A lane that lists
`CSRFProtection` ahead of `Sessions` by mistake would see `nil` on every
request under the graceful-pass-through rule and silently protect nothing
— exactly the class of failure the conformance and
`DispatchBuilder`'s ordering check exist to turn into a startup error
instead. Composing correctly costs an application nothing extra: a lane
with `CSRFProtection` and no `Sessions` at all never triggers the check,
because there is no `Sessions` entry for the reader to be listed before.

**Alternatives.** Double-submit cookie (a second, non-`httpOnly` cookie the
client echoes back; weaker under any subdomain that can set cookies, and
this package already has the session to build the stronger pattern on).
Per-request rotating tokens (OWASP's own guidance calls per-session
sufficient and per-request unnecessary complexity with a real multi-tab,
back-button UX cost). Reading the token from a form field in addition to
the header (rejected above). Refusing a session-less request outright
(would make every bearer-token route carry session machinery it has no use
for).

**Cost of reversing.** `Session.csrfToken()`, `CSRFToken`, and
`CSRFProtection` are additive; nothing else in the package reads
`X-CSRF-Token` or the reserved session key.

---

## D35 — Password hashing depends on the Argon2 reference implementation directly, pinned by revision

**Corrected by D37.** The `revision:`-pinned dependency below turned out to
break SwiftPM resolution for any consumer enabling `Security` through an
ordinary `from:` requirement — a real, concrete problem this entry did not
anticipate, found only once a downstream consumer actually tried it. D37
replaces the external dependency with a vendored copy of the same six
files, for that reason specifically; the reasoning below is kept as the
record of what was tried first and why, not as the current state of
`Package.swift`.

**Context.** A first-party credential story needs a hashing primitive, and
"no hand-rolled cryptography" means it has to be delegated, the way JWT
verification is delegated to JWTKit. Nothing plays JWTKit's role for
password hashing. Checked before choosing anything: `swift-crypto` itself
(a PR adding Argon2id, #427, was declined by Apple's own maintainers, who
cited the lack of a BoringSSL backend and suggested a standalone package
instead); the standalone-package ecosystem that suggestion points at
(several small, individually maintained Swift wrappers around the
reference C implementation, none with the release cadence, contributor
count, or audit trail the rest of this package's dependencies have).

**Chosen.** Depend on `P-H-C/phc-winner-argon2` directly — the actual
reference C implementation, from the algorithm's own designers, winner of
the Password Hashing Competition, the source RFC 9106 is built from and
that essentially every other language's Argon2 binding wraps. It ships its
own SwiftPM manifest, building only the portable reference sources
(`blake2b`, `argon2`, `core`, `encoding`, `ref`, `thread` — the
SIMD-optimized path and the CLI/benchmark/test tooling excluded), dual
CC0-1.0/Apache-2.0 licensed. `Argon2idHashing` in `FlightSecurityCore` is
orchestration around it: UTF-8 encoding, salt generation via
`SystemRandomNumberGenerator` (the same source `SessionID.generate()`
uses), and parsing its own parameters back out of the PHC string it
produces for `needsRehash`. No hand-rolled cryptography anywhere in this —
the C source is untouched, and the parsing is of Flight's own output, not
of arbitrary input.

**Pinned by `revision:`, not `from:`.** The repository carries no semver
tags — only date-stamped ones through 2019 — so `.package(url:, from:)`
cannot express this dependency at all. The last real commit is from 2021,
which reads less like abandonment than like a reference implementation of
a now-finalized RFC that has been correct and stable since. A `revision:`
pin names an exact, auditable commit, which for a cryptographic primitive
is arguably a more honest spelling of "here is precisely what we depend
on" than a semver range ever is — the same reasoning, differently applied,
that already justified pinning JWTKit as the first deliberate exception to
the Apple-adjacent/SSWG dependency policy.

**Why this does not reverse "no hand-rolled cryptography."** It cannot,
because nothing here is hand-rolled: the primitive is exactly as delegated
as JWT verification or TLS chain validation already are. What moves is the
dependency-sourcing policy, one exception further from "Apple-adjacent or
SSWG" toward "the most authoritative available source," which is the
policy JWTKit already established the shape of.

**Why this does not (yet) reverse "no first-party credential checking."**
`PasswordHashing` is a primitive, not a system. There is no
`CredentialStore`, no login route, no account model, and none of those are
built by this decision. They are a separate, larger piece that would sit on
top of this one, deliberately sequenced after it rather than alongside it.

**Alternatives.** Any of the small third-party Swift Argon2 wrappers
(inherits their own, thinner trust profile on top of the same C code, for
no benefit over depending on the C code's own package directly). Vendoring
the reference C source into Flight's own tree, as `CFlightZlib` vendors a
systemLibrary shim for zlib (rejected: zlib is preinstalled everywhere and
`CFlightZlib` only wraps the system's own copy; Argon2 is not preinstalled
anywhere, so vendoring it would mean Flight owning the update cadence of
someone else's cryptographic C source, which is strictly worse than
depending on the authors' own repository at a pinned commit). Waiting for
swift-crypto (Apple's own maintainers already declined the addition; there
is nothing to wait for). Bcrypt or scrypt instead of Argon2id (OWASP's
unqualified recommendation is Argon2id when there is no library
constraint forcing a fallback, and this decision exists to remove that
constraint, not accept it).

**Cost of reversing.** The dependency and the two files that use it
(`PasswordHashing.swift`, `Argon2idHashing.swift`); nothing else in the
package references either.

---

## D34 — Client address: raw peer always available, trusted-proxy resolution defaults to trusting nothing

**Context.** `Request` had no peer address at all — flagged repeatedly
(the September rate-limiting audit, then D33's own scoping decision) as
the prerequisite nothing had built. Two separable problems hide inside "add
the client's IP": capturing the socket peer at all, and deciding how much
of `X-Forwarded-For` to believe once a reverse proxy is in the picture. The
second is the one with a wrong answer that looks like a right one — trusting
the header from an unconfigured peer lets any caller claim to be any
address, silently, with no error anywhere.

**Chosen.** Four things.

1. **`Request.remoteAddress`**, populated by `FlightTransport` from
   `channel.remoteAddress`, is the kernel's answer and nothing else. It is
   never `X-Forwarded-For`, and reading it never involves that header.
2. **`RequestContext.clientAddress`** is the policy-resolved value:
   `remoteAddress` unless `TrustedProxies` says otherwise. `WebRuntime`
   carries it as a third citizen alongside `coders`/`errorMapper` — composed
   once, applied per request.
3. **The default is `.none`**, no permissive spelling exists, and none was
   added. Every other safe default in Flight (`Cookie`, `Sessions`,
   `RateLimiting`'s required key) at least has a documented narrow escape
   hatch for a legitimate case. This one does not get one, because there is
   no legitimate use for trusting an unconfigured forwarded header — unlike,
   say, `JWKSTransportPolicy.allowInsecureLoopback`, which exists for a real
   local-development case.
4. **Resolution walks `X-Forwarded-For` from the hop closest to this
   process backward, stopping at the first entry that is not itself a
   trusted proxy.** That entry is the client. Nothing left of it is ever
   used, because that is exactly the part of the header an untrusted caller
   could write by hand before its request ever reached the first real proxy.
   A chain with no untrusted boundary anywhere, or an entry that does not
   parse, resolves to `nil` rather than guessing — the same "say so rather
   than guess" instinct `RateLimitDecision.isUnsatisfiable` and GCRA's
   exact-microsecond fix both follow.

**Why `PeerAddress` is boxed on `Request`, not inline.** Measured: inline,
`RequestContext` grew to 152 bytes, breaking the two-cache-line bound
`RequestContextLayoutTests` pins with zero headroom left after Sessions.
Boxed behind a `final class`, it costs the one pointer `Session` already
costs. The public API is unchanged either way; this is storage, not shape.

**Why `inet_pton`/`inet_ntop` rather than a hand-rolled parser.** IPv6's
compressed forms have enough edge cases that betting on the platform's own
libc, which every other piece of server software on the machine already
trusts for this, is the safer bet than a parser written for this one
purpose — the same reasoning that keeps JWT verification in JWTKit rather
than in this package.

**Alternatives.** A numeric "trust N hops back" instead of named CIDR
ranges (weaker: a request that happens to cross exactly N untrusted hops
before reaching a trusted one would be misread, and it says nothing about
*which* infrastructure is trusted, only how much of it). Supporting RFC
7239 `Forwarded` in addition to `X-Forwarded-For` (real proxies and load
balancers overwhelmingly set the latter; the escape hatch —
`context.request.headers[.forwarded]` — costs nothing and the parser costs
a more intricate grammar for a header almost nothing sets). Trusting the
header whenever *any* proxy config exists, without per-range checking
(exactly the mistake this decision exists to avoid).

**Cost of reversing.** `Request.remoteAddress` and `WebRuntime.trustedProxies`
are additive fields; nothing consumes `X-Forwarded-For` unless
`TrustedProxies` is configured, so removing the feature costs exactly the
files that implement it.

---

## D33 — The limiter is its own target, its store decides and records in one call, and it fails open

**Context.** Rate limiting was pinned in the 2026-09-19 web audit, stalled on
a prerequisite: there is no client IP anywhere in flight, and keying a
limiter on a spoofable identifier is worse than not having one. Meanwhile a
first-party password story needs login throttling, which is the same
mechanism.

**Chosen.** Four things.

1. **`FlightRateLimit` is a dependency-free target**, below both `FlightWeb`
   and anything in Security. The `RateLimiting` middleware is one consumer;
   a login throttle and a worker pacing an outbound API are others, and none
   of them should need an HTTP server for a limiter to exist. Same shape as
   `FlightSessions` sitting below `FlightWeb` and `FlightSecurityCore`.
2. **`RateLimitStore` has one method.** `consume(key:cost:quota:)` decides
   and records together. A split API has no correct concurrent use: two
   callers read the same under-quota state before either writes, and both
   are admitted.
3. **GCRA**, not a fixed or sliding window. A fixed window admits twice the
   quota across a boundary; a sliding-window log is unbounded memory per key
   and an O(n) prune per call. GCRA is one timestamp per key, which is also
   why the distributed store is one `EVAL` with no lock.
4. **The middleware fails open** when the store cannot answer, loudly, per
   request, with `.deny` available per lane.

**Why (4) reverses D28's rule rather than following it.** Sessions fails
closed because a store that reads empty signs users out and there is nothing
behind it. A limiter exists to keep a service up under load; one that
refuses every request when *it* is unwell has inverted its own purpose, and
turns a dependency blip into a full outage. The warning is per request
because a limiter silently not enforcing is precisely the failure nobody
notices, and a single startup line would not say it is still true an hour
later.

**And the IP question is answered by scoping, not by waiting.** The key is a
required closure with no default, so an application keys on whatever it
already has: a subject, an API key, a login identifier, a path. Address
keying becomes one more available key when the transport work lands, with
nothing built here changing shape. The prerequisite was never the limiter.

**Alternatives.** Put the limiter in `FlightWeb` (would have forced an HTTP
dependency on the login throttle that motivated it). Default the key to the
client address (the identifier that does not exist, and would be spoofable
if it did). Fail closed for consistency with Sessions (rejected above).
Delay refused requests until a permit frees instead of refusing (turns a
limiter into a latency source and a memory exhaustion surface).

**Cost of reversing.** The seam is one method and the algorithm is one
file; the middleware is the only thing an application touches directly.

---

## D32 — APNs is hand-rolled on AsyncHTTPClient and JWTKit, sends one push per call, and uses token auth only

**Context.** A push client is a provider JWT, an HTTP/2 POST, and a table
of Apple's reason strings. APNSwift exists and does all three.

**Chosen.** Write it: `ProviderTokenSource` over JWTKit's key collection,
`AsyncHTTPAPNSTransport` over the shared `HTTPClient`, `APNSError.Reason`
as the table. One `send` is one delivery attempt; the client retries only
on `ExpiredProviderToken`, once. `.p8` token authentication only.

**Why.** The same reasoning as the JWKS fetch in Security Core: Flight owns
orchestration, the cryptography is delegated, and the HTTP is small enough
that owning it is cheaper than depending on it — and the hermetic seam
(`APNSTransport`) has to be this package's whichever way. APNSwift would
bring the same two dependencies and a payload model larger than this whole
target. One push per call because the right queueing and backoff depend on
what the pushes are, and a client that guesses surprises; the application
already has a scheduler and task groups. Token auth because Apple recommends
it, one key serves every app on the team, and it needs no client-certificate
plumbing in the transport.

**Alternatives.** Depend on APNSwift (rejected above). A `sendAll` with a
concurrency limit (an invitation to build the queue here after all). A
dedicated `HTTPClient` with tuned idle timeouts (would give the module a
`service`; nothing has needed it — the shared client pools the connection).

**Cost of reversing.** The transport seam makes swapping the HTTP layer a
local change; the notification model would survive a move to any library.

---

## D31 — `Sessions` before `Authentication`: owned by the security module, idempotent, and checked

**Context.** Session-backed identity needs `Sessions` to have run before
`Authentication` reads `context.session`. The two live in different modules,
and neither depends on the other: an application may have sessions without
security or security without sessions. D2 derives cross-module lane order
from the module graph in scan order, which is deterministic but implicit —
listing `FlightSecurityModule` before `FlightSessionsModule` in an
application's `dependencies` would silently sign nobody in.

**Chosen.** Three things together:

1. `FlightSecurityModule` takes `sessions: SessionRuntime?` by type and,
   when it has one, puts `Sessions` ahead of `Authentication` in every lane
   *it* declares, including its default-lane contribution. The lanes are its
   to order.
2. `Sessions` is idempotent: if the context already carries a session, it
   passes through. So the default lane holding it twice — once from each
   module, in whichever order the graph puts them — costs one load and one
   commit.
3. A `SessionReading` marker protocol on the reader, and a composition-time
   check in `DispatchBuilder` over each route's concatenated chain: a reader
   ahead of the first `Sessions` fails startup naming the route and both
   layers. A chain with no `Sessions` at all is left alone; the reader sees
   `nil` and that is its documented case.

**Why.** Ownership removes the ordering question for the lanes that matter;
idempotence removes the double-listing cost that ownership creates; the
check catches the one remaining way to get it wrong, an application's own
lane, at startup rather than as a browser that never signs in.

**Alternatives.** Make `FlightSecurityModule` depend on `FlightSessionsModule`
(forces sessions on every token-only API). Have `Authentication` load the
session itself (a second store read per request, and two owners of one
cookie). Rely on D2's scan order and document it (works until someone
reorders a list nothing checks). A string-suffix check on middleware names
instead of the protocol (couples FlightWeb to a type name in a package above
it).

**Cost of reversing.** The marker protocol, two flags on
`MiddlewareRegistration`, one check, one guard line in `Sessions`.

---

## D30 — The session cookie is `Secure` unless configuration says otherwise

**Context.** `Cookie` defaults `isSecure` to false, with a reason written at
the declaration: a development server on loopback has no TLS, and a cookie
that silently never gets set is a worse failure than one that is explicitly
insecure in development. `SessionSettings` had to choose whether to inherit
that.

**Chosen.** `sessions.cookie-secure` defaults to `true`.

**Why.** The bare cookie API cannot know its deployment. The session module
knows exactly what its cookie is — a bearer credential for everything the
session holds — and sending it over plaintext once is enough to lose it. A
default that is safe in production and one line in `flight-dev.yaml` in
development is the right way round for that cookie specifically. Chrome and
Firefox accept `Secure` cookies from `http://localhost`; Safari does not,
which is what the dev-overlay line is for.

**Alternatives.** Inherit `Cookie`'s false (safe development, unsafe
production, the wrong way round). Decide from whether the transport has TLS
configured (wrong behind a TLS-terminating proxy, which is the common
deployment). Decide from `FLIGHT_ENV` (an allowlist of development names,
the way Actuator gates its dashboard — defensible, but a second mechanism
for a one-line setting, and one that would fail *open* on an unrecognised
environment name unless it were also an allowlist).

**Cost of reversing.** One default and one test.

---

## D29 — `Session` is a reference type on the context

**Context.** `RequestContext` is a value, copied per middleware layer; a
handler's writes to its session have to reach the `Sessions` middleware
that persists them after `next` returns. `Next` deliberately takes no
`inout`.

**Chosen.** `Session` is a `final class` with a `Mutex`-guarded state, held
as an optional field on the context. The middleware writes the reference
into the copy it hands downstream and reads back what the handler did
through `Session.commit(now:ttl:)`.

**Why.** It is the smallest thing that gives the value-typed context
mutable per-request state: 8 bytes on the context (120 → 128, still two
cache lines, and `RequestContextLayoutTests` pins it), no `inout`, no
ambient lookup. `WebRuntime` is the standing precedent for a reference on
the context. The `PrincipalHolder` this resembles was removed because it was
*resolved out of a container scope*, not because it was a reference.

**Alternatives.** A task-local bound around `next` — works now that the
chain is layered, and is what `Principal.current` is; it is second-class
there for the same reason it would be here, that a value on the context is
readable without an ambient lookup. A seam protocol in FlightWeb with the
concrete type above it, D7's shape — unnecessary, because `FlightSessions`
sits *below* FlightWeb and can be named directly.

**Cost of reversing.** The field, the accessor, and the commit call in the
middleware.

---

## D28 — The session store throws, and the middleware fails closed

**Context.** flight-data's `Cache` never throws: a miss is normal, an
errored get is a miss, an errored set is dropped, because the correct
answer to any cache failure is the real computation behind it. The obvious
move was to reuse `any Cache` as the session store, or to copy its rule.

**Chosen.** `SessionStore` is its own three-method seam, every method
throws, and `Sessions` answers a store failure with a bare 503 — on load
and on save.

**Why.** There is no real computation behind a session. A store that
silently read empty would turn "signed in" into "signed out" without a word
anywhere; a save that silently dropped would lose a login after the handler
had already reported success. Both are worse than a 503 the operator sees.
The one failure that is *not* refused is a record under a well-formed id
that does not decode — that is not the client's doing, and starting fresh
with a logged warning is the honest answer.

**Alternatives.** Reuse `any Cache` (wrong semantics, above, plus a
`CacheKey` namespace the session does not need). A fail-open middleware
over a throwing store (the same wrong semantics one layer up). A retry
inside the middleware (hides the outage from the operator for exactly as
long as it lasts).

**Cost of reversing.** Contained: the seam has three methods, and the
middleware's two `catch` blocks are the whole policy.

---

## D27 — Two providers of one type: a declared default, `@Inject(from:)` for the rest

**Status: agreed, not yet implemented.** Written before the code so the
rejected alternatives are on the record rather than reconstructed afterwards.

**Chosen.** Three changes, and the first is not optional:

1. **Module identity keeps its generic arguments.** `moduleKey`
   (`flight-registration-gen/main.swift:963`) strips everything from `<`
   onward, so `PostgresDataModule<PrimaryDataSource>` and
   `PostgresDataModule<Analytics>` share one key, get **one** binding, and both
   parameters receive it. Verified by probe — the composer emits
   `let poolModule = PoolModule<Primary>()` followed by
   `AppModule(primary: poolModule, analytics: poolModule)`, and the build fails
   with `cannot convert value of type 'PoolModule<Primary>' to expected
   argument type 'PoolModule<Analytics>'`.
2. **`defaultProviders`, declared by the application's own module**, consulted
   *only* when two or more modules provide the same type.
3. **`@Inject(from: PostgresDataModule<Analytics>.self)`**, naming a provider
   by module type, for the component that wants the non-default one.

```swift
struct AppModule: FlightModule {
    static var dependencies: [any FlightModule.Type] {
        [PostgresDataModule<PrimaryDataSource>.self, PostgresDataModule<Analytics>.self]
    }

    /// What an unqualified `@Inject var pool: PostgresDataSource` means.
    static var defaultProviders: [any FlightModule.Type] {
        [PostgresDataModule<PrimaryDataSource>.self]
    }
}
```

**Why the generic-argument fix comes first.** flight-data is built on
`Module<Name>`-per-datasource — `PostgresDataModule`, `InMemoryDataModule`,
`ValkeyDataModule` — and `Docs/data-core.md` documented composing two of them
from the beginning. It has never worked. Nothing caught it because
`GeneratorTests:1359` covers exactly one instantiation and asserts its binding;
no test composes two. The same defect class as everything the 2026-09-17 audit
found: the test exercises the code beside the seam.

**Why a default at all, rather than requiring `from:` everywhere.** Without
one, adding a second pool breaks every existing injection. Two providers make
`@Inject var pool: PostgresDataSource` ambiguous, so every repository that
wants *the* pool — all of them, none of which care about analytics — stops
compiling. The tax has to fall on the application with the unusual shape, not
on every consumer in it.

**Why the default is declared in the application.** It cannot live in
flight-data: `PostgresDataModule<Name>` is a single declaration and cannot mark
one instantiation special. It cannot live on `PrimaryDataSource` either,
because the build plugin scans only the application's own target and never sees
flight-data's sources. Where the instantiations are named is the one place the
generator can read it.

**Why not "first in `modules:` wins".** That is F1 — service shutdown order came
from however the application happened to list its modules, and the order every
example showed was the wrong one. Ordering in that array is not a place to put
meaning.

**Rejected: a string qualifier.** `@Inject("analytics")` was removed in 0.20.0
because it never reached the wiring — composition keys on type, so two
same-typed properties silently received the same instance. Restoring it under a
new name would restore the same lie.

**Rejected: key paths — `@Inject(from: \.dataSource)`.** Rejected on review, and
rightly: that spelling only reads sensibly if there is a registry to index into,
so it would import the mental model 0.17.0 removed, and create a second
namespace competing with the type-based one. Worse than the string qualifier,
because it looks principled.

**Rejected: phantom-typed values.** `PostgresDataModule<Name>` providing
`PostgresDataSource<Name>` needs no default, no `from:`, and no new `@Inject`
surface — there are simply never two providers of one type. It is the more
principled DI and it was close. It loses on the tax: the parameter appears in
every single-pool signature in the ecosystem, including `Repo`, `withRepo` and
every repository, to serve a shape most applications do not have.

**It costs nothing until it is needed.** One provider: no `defaultProviders`,
no `from:`, code identical to today. The feature is invisible until the day a
second `PostgresDataModule` is added.

**The diagnostic is the feature, not decoration.** On that day the build must
hand over the fix: name both providers and the type, list the consumers asking
for it by type with their own file and line, and show the `defaultProviders`
block and the `@Inject(from:)` line to paste. Three constraints on it:

- **An error, not a warning.** A warning means composition picks one and
  continues, which is the silent misbinding 0.20.0 deleted. There is no
  defensible guess — the framework genuinely does not know.
- **One per ambiguous type, not per consumer.** Twelve repositories injecting
  the pool is one diagnostic listing twelve, not twelve diagnostics.
- **Reported against the application's source.** Today `#error` surfaces at
  `FlightRegistration.generated.swift`, which is nobody's code.

This depends on a diagnostics fix landing first: a dependency the composer
cannot resolve currently emits an editor placeholder into compiled output
(`try FlightGraph(pool: <#nothing provides Pool#>)`, an
`error: editor placeholder in source file`), *and* the correct ambiguity
message, *and* a third error claiming nothing provides the type when two things
do — because `provider(of:)` returns nil for both absence and ambiguity and the
caller cannot tell them apart.

**What reversing costs.** `defaultProviders` and `from:` are additive and can
be deleted with their diagnostics; nothing else reads them. The module-identity
change is not reversible in the same sense — it is a bug fix, and reverting it
restores a composer that silently hands one instantiation where another was
asked for.

**Landing order.** Diagnostics first, alone, since it is a bug fix and makes
the rest debuggable. Then module identity, which is independently valuable and
makes flight-data's documented shape work with no new API — a release could
stop there. Then `defaultProviders` and `from:` together, since neither is
useful without the other. flight-data's docs and Adversary's withdrawn
`analytics` probe are restored last, and the restored probe is the end-to-end
test.

---

## D21 — Scheduled jobs are values, and the coordinator is an argument

**Chosen.** `@Scheduler` generates `_flightScheduledJobs(_ make:)` beside its
`_flightRegister`, the generator emits `flightScheduledJobs(_ graph:)`, and
`FlightSchedulerModule(jobs:coordinator:)` takes both. `SchedulerService` takes
what it runs; its `Container` and `resolveCoordinator` are gone.

**Why.** This was the module I said was blocked, and the graph move unblocked
it exactly as predicted: a job's closure needed its component at *firing* time,
and with the graph a composition value the closure captures it instead of
resolving it. The macro already had the shape — a value form beside a
registration form is what `@Controller` does with its route factories.

**The coordinator is the more important half.** It was
`resolve((any JobCoordinator).self)`, catching `.notRegistered` to mean
single-process — PubSub's and Presence's anti-pattern a third time, and the
one with the worst failure: an operator who believes `.once` means once, running
several servers, finds out from duplicated data. Whether a deployment has
something to coordinate *through* is a fact about how it was composed. The demo
had exactly this exposure: it registered a `PostgresJobCoordinator` the
scheduler would no longer have read, so it now provides it as a property.

**`isTypeConstructible` stays true here**, unlike the other converted modules:
a scheduler with no jobs is a legal application, so `init()` produces something
correct rather than something misconfigured.

---

## D26 — Actuator lists what the build scanned, not what the container holds

**Chosen.** The generator emits `flightComponentDescriptors()`, the composer
passes it to `ActuatorModule(components:)`, and `ActuatorController` holds that
list instead of a `Container`. Module health — genuinely runtime state — still
comes from the tracker, through a `@Sendable () -> [ModuleStatus]` closure.

**Why.** `container.allRegistrations()` was the dashboard's source, and it was
the last thing in Actuator holding a container. What the build scanned is the
better answer under composition: it is what the graph constructs, and it exists
before the process does. §2.9 said Actuator's introspection would be rebuilt on
the static manifest; this is that.

**What changed in the output, and it is worth knowing.**
- Routes are no longer listed *as components*. The container held a
  `RouteRegistration` per route and `allRegistrations()` could not tell it from
  a service, so the demo's dashboard counted eight components where the build
  scanned seven. Routes are reported as routes.
- Anything registered through the imperative escape hatch is invisible to the
  list, because no scan sees it. That is the deliberate trade.
- A framework module's own components are invisible for the same reason, so
  `ActuatorModule` declares its controller in `ownComponents`. A module knows
  what it provides; it says so rather than relying on the dashboard to notice a
  registration.

**Cost.** `ComponentDescriptor`'s memberwise initializer becomes public,
because generated code in the application's module constructs it.

**Not deleted:** `ActuatorSnapshot(container:environment:)`, a documented
convenience for anyone building their own surface. Only tests use it now. It is
not what keeps `Container` alive — see below.

---

## D24 — A route terminal's own roots are not graph properties

**Chosen.** `FlightGraph` stores only what a *component* needs. A dependency
that only a controller has becomes a parameter of `flightRoutes(_:…)` instead.

**Why.** This is what unblocked channels. A controller injecting
`ChannelBroadcaster` made it a graph root, so `FlightGraph` depended on
`FlightChannelsModule` — and `FlightChannelsModule` takes the channel list, so
*nothing that builds channels from the graph could ever compose*. The build
said so, by name, the moment I tried.

The fix follows from what the graph is: a controller is **not a component**.
It is constructed by its terminal, per request, and never stored. So a value
only it needs belongs to the terminal, not to the graph. The demo's graph went
from six roots to two.

**What it makes possible.** `DemoChannelsModule(graph:presence:)` — a module
that takes the graph *and* provides what Channels is built from, which was a
cycle an hour earlier.

---

## D25 — A channel is handed what Channels owns; it closes over the rest

**Chosen.** `ChannelRegistration`'s factory takes a ``ChannelContext`` —
topic, broadcaster, principal — instead of the upgrade's `RequestContext`.
Everything else a channel needs is an ordinary value its declaring module
closes over.

**Why the split is exactly there.** A channel is declared by a module that
`FlightChannelsModule` is *built from*, so it cannot depend on Channels at
construction. At join time there is no such problem: the broadcaster has
existed since composition. So the values Channels owns arrive per join, and
everything else — repositories, services, presence — arrives by ordinary
capture.

**What it fixed beyond the lookup.** The factory used to take the
`RequestContext` the socket was upgraded from, which meant a channel created
ten minutes into a socket's life reached back through the request that opened
it. Nothing depended on that, and now nothing can.

**Result.** No template code calls `context.resolve`. The framework has one
call left, in `ChannelSocketHandler(context:)` — the imperative escape hatch,
in the same category as `container.registerRoute`.

**Not done: the `@Channel` macro.** Declaring channels as types with `@Inject`
properties would be the natural third instance of the routes/jobs pattern. It
is sugar over what now works, and worth doing when channels get complicated
enough to want it.

---

## D23 — The outbound writer does not get a vote on why a socket closed

**Chosen.** The writer task no longer yields `.normal` when its queue
finishes, and the frame loop records its close intent *before* tearing the
session down.

**The bug.** `invalidEnvelopeCloses` intermittently saw close code 1000 where
4400 was documented — only under parallel execution, never in isolation. It was
not a flaky test. Three tasks feed one `AsyncStream<CloseIntent>` and the
handler takes the first: "first exit wins". The undecodable-frame path read

    await session.teardown()
    finishedContinuation.yield(protocolViolation)

and `teardown()` finishes the outbound queue — which wakes the writer, whose
last act was `yield(.normal)`. Under contention the writer's `.normal` beat the
violation the frame loop had *already decided on*, and the peer was told the
socket closed normally. The `.binary` path had the identical shape, and the
graceful `flight:close` path could lose its code and reason the same way.

**Why the writer stays silent now.** Its queue finishing is a *consequence* of
teardown, never a reason to close — and teardown always follows a decision made
somewhere else. The one reason that task genuinely owns, a write timing out, is
still yielded, before its `break`. Nothing is lost: whatever tore the session
down also ends `connection.frames`, and the frame loop's own `.normal` covers
the no-reason case.

**Verified** by 20 consecutive runs of the channels suite with zero failures;
the rate before was roughly one in six.

---

## D22 — A socket route injects the channels stack; the crash was a stale build

**Chosen.** `ChannelSockets` bundles the router, the bus and the channels
configuration as one injectable value. `FlightChannelsModule` builds it,
provides it, and offers `socketRoute(_:)` built from it. A declared route
injects it; `ChannelSocketHandler(context:)` survives as the imperative escape
hatch with one lookup instead of three.

**The crash, and what it actually was.** Adding `let sockets` to
`FlightChannelsModule` segfaulted the channels client suite — SIGSEGV, frame 0
a garbage address, frame 1 inside `TestContainer`'s module block. It reproduced
with the stored property alone, nested or top-level, with and without the
registration. It was **a stale incremental build**: changing a public struct's
stored properties changes its layout, SwiftPM did not rebuild a dependent test
target, and the test binary jumped through a pointer computed from the old
layout. `rm -rf .build` and it passes.

This cost a full revert of a correct design, and the lesson is worth stating
plainly: **a SIGSEGV after changing stored properties in a library target is a
stale build until proven otherwise.** Clean-build before concluding anything
about the code. Nothing in Flight can guard against it; only the habit can.

**What it exposed on the way.** Injecting `ChannelSockets` makes it a root of
the component graph, so the build refused the composition by name:
`AppModule`, `FlightChannelsModule`, `FlightGraph` and friends formed a cycle.
The rule this makes concrete — **a module that provides a graph root cannot
also take the graph** — is the same one that split `DemoAuthModule` out, and it
split the demo's channels into `DemoChannelsModule`. The cycle diagnostic from
D14 earned its keep here: it named the problem instead of producing code that
failed to compile for an unrelated-looking reason.

**And a real generator bug.** The graph emitted a component's dependencies as
injected-then-acknowledged, while the generated initializer takes them in
*declaration* order — so a `flight:hand-registered` property declared before an
injected one produced `SocketController(sockets:validator:)` against
`init(validator:sockets:)`. Invisible until a controller had both in that
order. `ScannedComponent.dependencyOrder` records declaration order; there is a
regression test.

---

## D20 — Web takes the route table; the registries stop being container scans

**Chosen.** `FlightWebModule(configuration:routes:middleware:assetMounts:coders:)`.
`DispatchBuilder` gains a value-based `build(routes:middleware:assetMounts:container:)`,
and the container overload delegates to it. The generator emits
`flightRoutes(_ graph:) -> [RouteRegistration]` instead of registering routes,
and the composer folds it into the `[RouteRegistration]` aggregate alongside
every module's own.

**Why.** `DispatchBuilder.build(container:)` collected four registries
post-`freeze()`, which is what forced `FlightWebModule` to stash a container
and build the table at its service's first breath. With routes and middleware
as values the table is assembled during `configure`, so a conflicting route or
an undeclared lane fails there rather than at start-up.

**What moved with it.**
- `FlightSecurityModule(validator:)` holds `Authentication` and
  `RequireAuthentication` as instances and declares all three canonical lanes
  as `middleware`. It no longer registers middleware types, and
  `Authentication` is handed its validator once instead of resolving it per
  request.
- `ActuatorModule.routes` is a stored property — §2.9a's conditional
  installation is now an ordinary `if` over the exposure, not four
  `flight:hand-registered` calls.
- `RouteRegistration.channelSocket(_:)` is the value form of
  `registerChannelSocket`.
- `WebCoders` arrives as an optional parameter the composer fills by type. It
  used to be a scan: `configure` checked `allRegistrations()` for coders an
  earlier module had registered and stood down if it found any, so the answer
  depended on module order.

**What stays.** `container.registerRoute`, `pipeline`, and `assets` still work,
and `DispatchBuilder.build(container:)` still collects them — that is the test
seam and the documented imperative escape hatch. Only the production path is
values-only. `TestClient` gains `routes:`/`middleware:` for suites exercising a
module's declared endpoints.

**The one thing that got worse, and the fix.** Routes leaving the container
means Actuator's dashboard cannot see them through `allRegistrations()`. So
`FlightWebModule.configure` registers the routes it was composed with, for
introspection only — the table is already built. A controller that also
registers its own routes now collides, which is the duplicate check working:
the generated `flightRegisterAll` passes `includingRoutes: false`, and a
hand-written module must too.

---

## D18 — The composition root builds the component graph

**Chosen.** The generated composer builds `FlightGraph`, wiring its roots from
module properties by the same type matching a module's own initializer
parameters go through, and sorting it among the modules — after those providing
its roots, before those registering from it. `flightRegisterAll` takes the
graph (`flightRegisterAll(_:graph:)`) and projects from it;
`container.register(FlightGraph.self) { _ in graph }` replaces
`{ c in try makeFlightGraph(c) }`.

**Why.** Components were *already* projected from the graph — the registration
for each read `try c.resolve(FlightGraph.self).x` — so the graph was already
the single construction point. Only the graph's own construction still happened
at `freeze()`, from a container factory. Its roots are things modules provide
(a pool, a token validator), which is exactly what D14's value flow matches now
that a module holds what it provides. Nothing else had to move.

**What it unblocks.** This was the shared blocker under Web, Scheduler and
Actuator. A route terminal, a scheduled job and an actuator endpoint all need
components at *invocation* time; with the graph a composition value, they can
capture it instead of resolving it.

**Consequences.**
- `flightRegisterAll` is internal rather than public, because `FlightGraph` is
  internal — deliberately, since an application's components are internal by
  default and a public type cannot expose them. Nothing outside the target
  called it.
- An application module now takes the graph, so it declares
  `init(graph:)`, `isTypeConstructible = false`, and a trapping `init()`.
- A graph root nothing provides is a build error naming the type, and a module
  that both needs the graph and provides one of its roots is a composition
  cycle the build refuses by name. The demo hit the second: its
  `(any TokenValidator)` was registered inside `AppModule`, and splitting it
  into `DemoAuthModule` is the honest shape anyway — choosing how tokens are
  validated is a deployment decision, which is what "a real deployment lists
  `FlightOIDCModule` instead" already said.

**Alternative — keep `makeFlightGraph(container)` and leave the graph at
freeze.** Zero churn, and it keeps three modules blocked forever: a container
factory cannot see what the composition root knows.

---

## D19 — Postgres owns its pool

**Chosen.** `PostgresDataModule(configuration:)` builds `PostgresDataSource` in
its initializer and exposes it as `dataSource`; `PostgresPoolService` takes the
pool and loses both its `Container` and the `Name` generic parameter that
existed only to rebuild a qualifier for the lookup.

**Why.** The demo's graph needs a `PostgresDataSource` root, and a graph built
at composition can only be handed things that exist at composition. A bad URL
or pool size now fails when the module is built rather than at `freeze()` —
earlier, and at the place that chose the URL.

---

## D17 — Presence takes its adapter and monitor as arguments, and its service loses the container

**Chosen.** `FlightPresenceModule(configuration:localBus:gossipBus:adapter:membershipMonitor:)`.
The module holds the tracker; `PresenceService` is built from it and its
`Container` initializer is deleted, along with the `Source` enum that held
either and the `optionalMonitor` probe.

**Why.** Presence had PubSub's exact anti-pattern, twice: `resolve`, catching
`.notRegistered` to mean "not in this deployment", for both the adapter and the
membership monitor — and those two answers *decide the failure-detection mode*.
Whether a node is clustered, and whether the cluster can say who is up, are
facts about how the node was composed. The composition root knows them; a
runtime scan could only discover them.

The service's `Container` case existed for a specific reason that has now gone
away: the module registered factories, and bootstrap collects services during
`configure` — *before* `freeze()` — so the components did not exist when the
service was constructed and `run()` had to resolve them. A module that owns its
components has them before any container exists, so the `direct` initializer
that was "for direct embedding and tests" became the only one.

**Consequence worth noting.** Two dead helpers fell out immediately
(`optionalMonitor`, the module's `optional(_:_:)`), and the value flow wires
`localBus: flightPubSubModule.local, gossipBus: flightPubSubModule.bus` with no
edge declared anywhere — the two buses are distinguished by type alone.

---

## D15 — An aggregate parameter concatenates; that is what keeps extensions open

**Chosen.** A parameter typed `[T]` is an *aggregate*: the composer collects
every included module's `[T]` property and concatenates them in module order,
rather than demanding exactly one provider. `[K: V]` is not an aggregate.

**Why.** D14 treats two providers of one type as an error, which is right for a
value — two modules offering an adapter means the application must say which.
It is exactly wrong for a *contribution*. Channels, routes and scheduled jobs
are all "every module that has one, please", and refusing the second provider
would mean only one module in an application could ever declare a channel.

This is the whole extension seam. A package flight has never heard of writes
`public let channels: [ChannelRegistration]` and is wired in without the
application enumerating it — the same openness `container.registerChannel`
gave, minus the container and minus the post-`freeze()` collection that made
it a cycle.

**Cost of reversing.** The rule is four lines in the composer; the cost is in
what depends on it — routes and scheduled jobs are meant to follow.

**Alternative — one provider, and let the app merge them.** `FlightChannelsModule(channels: a.channels + b.channels)` written by hand in the composition root. Honest, and it makes adding an extension an edit to the application rather than adding a package. That is the property that matters most for extensions, so it loses.

---

## D16 — Channels' cycle was module granularity, not values

**Chosen.** `ChannelRegistration` is a value a module holds, `FlightChannelsModule(bus:configuration:channels:)` builds the router in `init`, and the factory takes the `RequestContext` the socket was upgraded from. `Container.registerChannel` and `collectChannelRegistrations` are gone.

**Why.** The reported cycle was: a module declaring a channel needs the `ChannelBroadcaster` that Channels provides, and Channels needs the declarations that module contributes. But the *values* form a chain — `bus -> ChannelBroadcaster -> RoomChannel` — with nothing circular in it. The cycle existed only because one module both provided the broadcaster and aggregated the declarations. Declaring a channel does not require having a broadcaster; *creating* one does, and that happens per join. Splitting those two moments dissolves it, with no phase system and no laziness.

**What it bought beyond the cycle.** Malformed and duplicate patterns now fail
when Channels is constructed, which is before the container is frozen rather
than during `freeze()`. The router is immutable from birth instead of being
assembled from whatever the container had collected.

**Why the factory takes `RequestContext`.** It is the shape a route terminal
already has, so when per-request construction lands (D10) channels convert
through the same path rather than needing their own. Holding it for the
socket's life is safe because ``Lifetime`` has exactly one case: every
component is a singleton, so resolving later is the same lookup.

**Why the pattern is parsed by `ChannelRouter`, not at the declaration.**
`FlightModule` requires a *non-throwing* `init()`, so a module that had to
`try` to state its own channels could not conform. Parsing in the router keeps
declaration non-throwing and puts every pattern failure in one pass at
composition.

**What `dependencies` means now.** Inclusion, not ordering. `AppModule` still
lists `FlightChannelsModule` — that is what pulls Channels into the
application — while the composer builds `AppModule` *first*, because Channels
takes its channels. The two meanings the property used to conflate are now
separate, and only the composer needs to know the second.

---

## D14 — The composer wires modules by value flow, and orders them by it too

**Chosen.** A module's public stored properties are what it *provides*. The
generated composer matches a module's initializer parameters against those
properties by type — emitting `flightPubSubValkeyModule.adapter` for
`FlightPubSubModule(configuration:adapter:)` — and topologically orders the
modules by the edges that match creates, on top of the declared-dependency
order.

**Why.** Inverting the adapter direction left an edge that `dependencies`
structurally cannot express: `FlightPubSubValkeyModule` must be built and
configured before `FlightPubSubModule`, but flight cannot declare a dependency
on flight-data, and flight-data declaring the reverse is exactly the coupling
the inversion removed. Something had to carry that ordering, and the value flow
already does — B takes a property of A, therefore A first. That is the real
edge; `dependencies` was always an approximation of it, hand-maintained.

Without this the composer omitted `adapter:` as an unsatisfiable optional, so a
clustered application composed as single-node. Not silently — PubSub's
`requireNoUnloadedAdapter` sees `pubsub.valkey.url` and fails assembly — but
the failure would have said "you configured Valkey and did not load its
module" to someone who had loaded it.

**Consequences.** Neither module names the other; the type is the whole
connection, which is what lets an adapter live in a package flight has never
heard of. Two modules providing the same type is refused rather than guessed
at, and a cycle is reported — both as `#error` in the generated file, so the
consumer's compiler points at the reason instead of at a downstream type error.

**What it cost to get right.** Matching by type made a module's own property a
candidate for its own parameter, and the composer emitted
`ActuatorModule(environment: actuatorModule.environment)`. The generator's own
fixtures did not catch it; building the demo template did. There is now a test.

**Alternative — declare the edge in `dependencies` after all.** Would mean
either flight depending on flight-data, or the adapter module depending on
PubSub, which is the coupling this whole change removes.

**Alternative — match by conformance rather than by written type.** Would let
`FlightPubSubValkeyModule` expose the concrete `ValkeyPubSubAdapter`. Rejected:
the generator scans source text and its conformance map only covers scanned
`@Component` types, so a plain adapter struct is invisible to it. Requiring the
provider to publish the existential is one word in the declaration and states
the contract — "provides an adapter", not "provides a Valkey adapter".

---

## D13 — A converted module says it cannot be built from its type; the walk refuses

**Status: superseded.** Nothing in this decision survives. `isTypeConstructible`,
`Flight.instantiateModules` and `TestContainer` are all gone, and so is
`BootstrapError.moduleRequiresConstruction` — because the walk this refuses
does not exist any more. Modules are constructed by the generated composer,
so there is no runtime path that builds one from its type and nothing to
refuse. Kept for the record of why the trap was replaced.

**Chosen.** `FlightModule` gains `static var isTypeConstructible: Bool`,
defaulting true. A module that takes what it provides sets it false, and every
path that builds a module from a type — `Flight.assemble(modules:)`,
`TestContainer.build`, both through the new `Flight.instantiateModules` —
checks it and throws `BootstrapError.moduleRequiresConstruction`, naming the
module and saying to pass the built instance or `composedBy:`.

**Why.** The PubSub conversion's `init()` had to do *something*, and trapping
was the only honest option: returning a misconfigured module is worse. But the
trap fires from wherever the dependency walk happens to reach it, and the walk
reaches a converted module most often as a **transitive** dependency the
caller never named. The demo's `BootstrapTests` lists `AppModule`,
`FlightSecurityModule`, `ActuatorModule` — none of them PubSub — and got a
`preconditionFailure` from `PubSubModule.swift:91` with no indication of which
of its three modules pulled PubSub in. A crash is also unrecoverable, so a
test suite cannot assert on it and CI reports a signal rather than a failure.
A thrown error at the one place a type becomes an instance costs one static
property, and turns the worst 3am failure in this migration into a sentence.

**What it also buys.** The flag is a machine-readable record of which modules
have converted, which the remaining six conversions can be checked against.

**Cost of reversing.** Small and shrinking. `isTypeConstructible` exists only
while `init()` does; both disappear together when §9 removes the type-based
entry points, at which point the compiler enforces what this flag currently
enforces at runtime.

**Alternative — change the protocol requirement to `init(configuration:)`.**
Then the walk could build every module, since the configuration is always in
hand, and `BootstrapTests` would need no change at all. Rejected because it
only defers the problem by one module: D11 says a module holds what it
provides, so `FlightChannelsModule` will take a bus, `FlightPresenceModule` a
store — values no configuration can supply. The requirement would break again
at the next conversion, having cost an explicit `init(configuration:)` on
every module in flight, flight-data, and every template.

**Alternative — let it trap.** Free, and what shipped for one afternoon. The
demo's failure above is the argument against it.

---

## D12 — Converting modules is one coordinated change, not seven local ones

**What I expected.** After D11 and the generated composer, converting each
framework module looked mechanical: take inputs in `init`, hold components as
properties, have `configure` project them. Both mechanisms stay live, so each
conversion is local and non-breaking.

**What happened.** I converted `FlightPubSubModule` — the best candidate: no
service, no held container, two components, and a doc comment that names the
exact constraint D11 removes ("they used to be `init` parameters, which meant
they did not exist"). The conversion itself was clean and the module reads
better. Then the suite trapped, and the reason is structural rather than
incidental.

**The finding: converting a module inverts its dependency direction, and the
inversions are mutual.**

`FlightPubSubModule` composes by *presence* today: its `(any PubSub)` factory
runs at `freeze()` and asks the container whether anyone registered a
`DistributedPubSubAdapter`. An adapter module therefore declares
`FlightPubSubModule` as a *dependency*, registers its adapter, and exposes
`PubSubRelayService(container:)` as its service.

Taking the adapter as an initializer parameter inverts that: the adapter must
exist *before* the bus that wraps it, so the adapter module becomes a
dependency **of** PubSub. But the relay needs the bus — which PubSub now
builds later. The two need each other, in opposite directions, and the knot
only unties by moving the relay from the adapter module to PubSub. That is
defensible, arguably better ("an adapter module provides an adapter; that is
all"), and it rewrites a documented, tested contract: `Docs/pubsub.md`'s
"Writing an adapter module", plus the suite asserting
`app.services[0].moduleName == "InMemoryAdapterModule"` and the transitive
DAG order.

Every other module has the same shape:

| Module | Needs, from where |
|---|---|
| Channels, Presence | `(any PubSub)` — so blocked behind PubSub |
| Security | `(any TokenValidator)`, which the *application* registers — inverts app→framework |
| Actuator | its controller holds the container (§2.9's introspection) |
| Web, Scheduler | their services resolve post-freeze, which is §3's wrapper category |

**So the order is: decide who provides what, once, across all seven.** The
container is what has been absorbing these inversions — late binding is
exactly what a registry buys, and removing it means every "someone will
register this later" becomes an explicit direction. That is the migration's
real remaining content, and it is a design pass rather than a conversion pass.

**Reverted**, deliberately: a half-converted PubSub with a trapping `init()`
would have broken every consumer's tests for no delivered benefit, and the
adapter contract deserves a decision rather than a side effect.

**What I would do next, if it were mine to choose:** take the seven modules
as one exercise, write down who provides what and in which direction — the
relay question is the template — and only then convert, PubSub first because
everything else waits on it. I would not start that without agreement on the
adapter direction, because it changes a documented extension point that
someone outside this repository may already have built against.

---

## D11 — A module is a value that holds what it provides

**The question.** `FlightModule.configure(_ container: Container)` is the last
thing keeping `Container` alive: 15 imperative registrations, the 7 framework
`context.resolve` sites that depend on them, and everything on §3's list that
those hold up. What replaces it, such that an optional subsystem's components
reach the generated graph *only when the application included that module*?

**Chosen.** A module stops registering components and starts **owning** them.
It declares what it needs as initializer parameters and what it provides as
stored properties:

```swift
public struct FlightChannelsModule: FlightModule {
    public static var dependencies: [any FlightModule.Type] { [FlightPubSubModule.self] }

    public let router: ChannelRouter
    public let broadcaster: ChannelBroadcaster

    public init(configuration: Configuration, pubsub: any PubSub) throws {
        let settings = try ChannelsConfiguration(configuration: configuration)
        self.router = ChannelRouter(settings: settings)
        self.broadcaster = ChannelBroadcaster(pubsub: pubsub)
    }
}
```

`FlightGraph` then holds the modules the application listed, and reaching a
framework component is `graph.channels.broadcaster` — two field loads, no
dictionary, no lock. Modules are nodes in the same graph as components,
ordered by the same `dependencies` DAG the runtime already resolves, taking
each other's products as parameters.

**Why this one.** It is what someone with no DI background would write. A
module is a struct with `let` properties and an `init`; the docs sentence is
"a module is a value that holds what it provides", and the follow-up question
"how do I get at what it provides" answers itself. There is no registry, no
bag, no lifetime vocabulary, and no second concept to learn — the mechanism a
module uses is the mechanism a component already uses.

It also deletes rather than adds:

- **Conditional inclusion stops being a runtime question.** The bootstrap
  list is a literal in the application's own source, which the generator
  already scans, and the `dependencies` DAG is already resolved there for
  lane ordering. A module the app did not list is simply not a property.
  That is what `flight:module-registered` exists to work around, and the
  marker goes with it.
- **The `service` timing workaround dissolves.** Modules hold a container
  today *only* because `service` is read before `freeze()`, so resolution has
  to be deferred into `run()` — §3 counts those wrappers as the largest
  category on the deletion list. A module that already holds its components
  can build its service from them directly.
- **The awkward cases get easier, not harder.** `(any PubSub)` falling back
  to a local implementation, and `PresenceTracker`'s three-way mode choice,
  are today container scans that ask "did anyone register an adapter". They
  become `init(adapter: (any DistributedPubSubAdapter)?)` and a `switch` —
  ordinary Swift, in the open, testable by calling it.

**Alternatives.**

- *Annotate framework components with their module* (`@Component(module:
  FlightChannelsModule.self)`). Smaller change, keeps `configure`. Rejected:
  it adds a concept — a back-reference from component to module — to preserve
  a mechanism we are trying to remove, and it does not touch the `service`
  workaround or the container-scan branches.
- *Attribute components by the Swift module they are declared in.* Needs no
  syntax at all and is tempting, but FlightSecurityCore declares both
  `FlightSecurityModule` and `FlightOIDCModule`; an app including only the
  first would get an OIDC validator built with no configuration. Too coarse
  by exactly the case §2.8 was built around.
- *Scan each `configure` body and transplant its registrations into the
  graph.* No new syntax, and it is the shape I reached for first. Rejected:
  a factory body is arbitrary Swift, so this is a source-to-source rewrite of
  `c.resolve(T.self)` into graph references — the "arbitrary wiring is
  genuinely lost" case §2.6 already identified, dressed up as automation.

**What it costs.** `init()` becomes an initializer with parameters, so
`Flight.bootstrap(modules: [Type.self])` cannot instantiate modules itself —
the generated composition root does, which is the same shift §2.8 declined to
make for the token validator alone and is now paid for once, for everything.
That is a breaking change to the first thing a new user encounters, and it is
the reason this is a decision rather than a refactor.

**Actuator's `FLIGHT_ENV` is a separate half, and stays separate.** The
module holding an `ActuatorController` is unconditional; whether its *routes*
install is the runtime question. That is §2.9a's install predicate — static
manifest entry, boolean evaluated once at boot — and it keeps the property
that a disabled actuator has no route rather than a route that 404s.

---

## D10 — Per-request construction is not shipped until the terminal can pass request values

**Context.** Step 6's spike proves per-request construction works for all
three response kinds, including the two that outlive dispatch. The obvious
next move is to make `@Controller` construct inside the handler closure
rather than capturing an instance resolved at `freeze()`. I did not.

**Why not.** Moving `try c.resolve(Self.self)` inside the closure buys the
*lifetime* and nothing else, because every component is a singleton now:
post-freeze resolution returns the same instance either way. What it costs is
a dictionary read per dependency per request, on every route. That is a
strictly worse trade until the terminal has something request-shaped to pass
— and nothing in the tree does yet, because §2.5 put the principal on the
context, which is where request values already travel typed and cheaply.

Per-request construction earns its cost when a controller's dependencies are
*visible in its signature* rather than read from the context ad hoc, and that
requires constructor injection from the graph — not a per-request locator
lookup wearing the same shape.

**So the order matters:** the graph must reach the terminal *first*, and then
construction moves. Shipping the lifetime change first would be measurable
cost for no behaviour, and would have to be undone.

**What shipped instead.** `makeFlightGraph(_:)` — the graph is now
*constructible*, not merely compilable, with its root parameters resolved
from the container. A function rather than a registration, because every
component is built eagerly at freeze and registering the graph would make a
missing root parameter fail the boot of an application that works today, for
a value nothing calls yet.

**The open decision**, recorded in §7 step 6 with trade-offs: how the
generated terminal gets graph values when `@Controller` expands in the
application's module and cannot know `FlightGraph` exists. My recommendation
is the macro emitting a per-route factory that takes a `make` closure, with
the generator supplying it — it keeps the handler thunk where it is, so the
drift `FlightRouteScan` was extracted to prevent stays prevented.

---

## D9 — `Lifetime` kept as a single-case enum, parameter defaulted

**Context.** §2.2 removed `.scoped` and `.transient`. `Lifetime` is now one
case, and `Container.register(_:qualifier:scope:stereotype:factory:)` still
takes it.

**Chosen.** Default the argument (`scope: Lifetime = .singleton`) rather than
remove the parameter.

**Why.** A single-case enum is zero-sized in Swift, so the parameter costs
nothing at runtime — removing it is API tidiness, not performance. Doing it
now would touch five macro implementations, the generator's bridge emission,
every module registration, 18 controller golden fixtures and the core macro
fixtures, in a change that buys no behaviour. Defaulting unblocks every call
site immediately and leaves the deletion as a clean, separable pass.

**Alternative.** Remove it now and absorb the churn while the surrounding
code is already moving. Defensible; I judged the review cost higher than the
benefit, and it can be done any time.

**Watch.** A one-case enum is an attractive nuisance — it reads as though
lifetimes are still a concept. If it survives to step 9 it should go.

**Resolved in 0.20.0.** It went, along with the `scope:` and `qualifier:`
arguments that named it and `ComponentDescriptor`'s two fields. The deferred
churn was smaller than this decision estimated: the container-era registration
sites it worried about had already gone with the container, so what remained
was three macro signatures, the generator's two emissions, and the fixtures.

---

## D8 — Long-lived responses are in scope, and what that requires is verified

**Context.** Step 6 constructs the request's object graph in the generated
route terminal. A streaming or upgraded response outlives the dispatch call
that produced it, so whatever the terminal built is still referenced after
dispatch returns. Confirmed as acceptable, provided those responses maintain
their own state and shut down gracefully while telling the client.

**Verified, not assumed.**

- **WebSockets.** `ChannelSocketHandler` routes a close *intent* from
  whichever task decided to end the session to the one place that writes the
  close frame, after every task has joined — the writer first, so queued
  frames reach the wire ahead of the close. Teardown is idempotent and runs
  `leave` per joined channel exactly once. Server-shutdown cancellation is an
  explicit path through it, and the documented close codes reach the client
  (they used to arrive as an abnormal 1006).
- **Streaming.** `Response.streaming` wires `onCancel: { producer.stop() }`,
  so a consumer going away — client disconnected, request task cancelled at
  shutdown — stops the producer rather than leaving it running against a
  stream nobody reads. Now pinned by a test; it was the one load-bearing
  property here with no coverage.

**The honest boundary.** Flight has no generic "server going away" *message*
for a byte stream. WebSocket has close codes; `.streaming` is opaque bytes
and SSE has no standard goodbye, so an application that wants to say
something on the way out sends it itself — it owns the writer. Flight's
guarantee is that the producer is stopped and nothing leaks, not that the
client is told why.

**Consequence for step 6.** Nothing the terminal constructs may own a
pooled resource (§2.12 already says this). With that held, a response
outliving dispatch is ordinary Swift lifetime and needs no scope.

---

## D7 — The request's identity is a seam protocol in Flight Web

**Context.** Step 3 moves the principal onto `RequestContext` as a typed
field. But `RequestContext` lives in FlightWeb and `Principal` lives in
FlightSecurityCore, which *depends on* FlightWeb — so the field cannot name
the type. This is the real reason the principal travelled as a `.scoped`
component: the container inverted a dependency the type system would not
allow directly. The stale "the middleware chain is flat" story was a second
reason, and the smaller one.

**Chosen.** FlightWeb owns `RequestPrincipal` — a two-member seam (`subject`,
`hasRole`) — and `RequestIdentity`, a three-case enum stored on the context.
`FlightSecurityCore.Principal` conforms.

**Why.** FlightChannels already solved the identical problem this way, and its
`ChannelPrincipal` doc argues the case: the package that needs to *read* an
identity owns a minimal protocol and depends on no particular identity
implementation. Using the same shape twice is cheaper to explain than two
mechanisms. It also keeps §2.5's "named fields, closed set, no
`get(Key.self)`" property.

**Alternatives.**

- *Move `Principal` down into FlightWeb or FlightCore.* Ends the cycle
  outright, but puts JWT-shaped identity in the web layer and makes every app
  that never authenticates carry it.
- *A typed side-table*, like the `ServiceContext` the context already holds.
  Works, and §6 concedes the "bags are wrong" premise was mistaken — but it
  reintroduces a `get(Key.self)` surface for one entry.
- *An opaque `any Sendable` slot* with typed accessors in FlightSecurityCore.
  Smallest change; a one-entry untyped bag wearing a field's clothes.

**Cost of reversing.** Contained: the protocol, the enum, one field, and the
accessors in `RequestContext+Principal.swift`.

**Measured.** The identity field costs 40 bytes (existential). `.anonymous`
carries no payload, so an unauthenticated request pays no retain/release
traffic when the context is copied.

---

## D6 — `RequestContext.response` deleted

**Context.** While sizing the context for D7 I measured it at **184 bytes**,
of which `response: Response` was 97. It was written in two places and read
in none: `Router.execute` assigned it and then returned the same value, and
`RequestContext.init` stored it.

**Chosen.** Delete the field and the dead store.

**Why.** It is vestigial from the flat pre-handler chain, where middleware
mutated a response in place and the chain returned it at the end. Under
`handle(_:next:) -> Response` the response *is* the return value. The context
is copied on every `next(context)`, so this was 97 dead bytes per layer per
request, and it is what pushed the struct across a third cache line.

**Result.** 184 → **120 bytes**, three cache lines → two, *including* D7's new
40-byte field. `RequestContextLayoutTests` pins the bound so crossing it again
is a decision rather than an accident.

**Alternatives.** Deprecate rather than remove — it is public API. Rejected:
it is dead, this migration is already breaking, and a deprecated field still
costs the bytes.

**Cost of reversing.** Trivial, but it would put the third cache line back.

---

## D5 — `AuthenticationState` kept, as a derived view

**Context.** With identity stored as `any RequestPrincipal`,
FlightSecurityCore's `AuthenticationState` (which carries a concrete
`Principal`) is no longer the storage.

**Chosen.** Keep it as a public type, computed from `RequestIdentity` on
read. An identity written by a *different* conformer reports `.anonymous`.

**Why.** `context.authenticationState` is documented public API and the
distinction it draws — no credential vs rejected credential — is what earns
the RFC 6750 `error="invalid_token"` challenge. Deleting it would break
callers for no gain.

**Alternative.** Delete it and let `RequestIdentity` be the only type.
Cleaner, one fewer concept, and a breaking change to a documented surface.
Worth doing if the seam ever grows a second conformer in practice.

**Watch.** The `as? Principal` downcast on every `context.principal` read. A
handler reading it several times pays several dynamic casts. Not measured;
suspected negligible against a request, but it is the one wart here.

---

## D4 — The generator scans routes silently

**Chosen.** `flight-registration-gen` runs the shared route scanner with a
diagnostics sink that discards everything.

**Why.** `@Controller` already diagnoses non-literal paths, static handlers,
bad signatures and upgrades with bodies, and both run in the same build.
Anything the generator reported would reach the author twice at the same
line. The macro owns reporting; the generator owns the manifest.

**Alternative.** Report from the generator and stop reporting from the macro.
Rejected: the macro's diagnostics render inline at the attribute in an IDE,
and a build tool's do not.

---

## D3 — Mounts are recorded; `registerRoute` is acknowledged

**Chosen.** `assets(at:)`, `uploads(at:)` and `registerChannelSocket` are
recorded as *mounts* from their call site. Direct `registerRoute` calls warn
unless marked `// flight:hand-registered`, and are named in the generated
file either way.

**Why.** A mount's call site carries the prefix the framework derives routes
from, so it is scannable even though the `registerRoute` calls inside the
convenience are not. Only the raw escape hatch is genuinely uncomputable, and
the component scan already had an answer for that shape.

**Alternatives.** Union the manifest with runtime collection (keeps the
container alive for routing, which is what step 4 removes); or hard-error on
unscannable calls (turns a working escape hatch into a build failure, first
in framework code the author does not own).

---

## D2 — Lane order is derived from the module graph, with scan-order roots

**Chosen.** Sort lane declarations by a depth-first walk of scanned
`static var dependencies` edges, using every scanned module as a root in scan
order.

**Why.** The runtime's roots are the bootstrap module list, which is outside
the generator's scope. Scan order reproduces the runtime wherever a
dependency path exists between two modules — the ordinary case, since an
application module depends on the framework modules it uses — and cannot
where none does.

**Mitigation.** The scanned edges are emitted as `moduleGraph`, so a consumer
holding the real bootstrap list can redo the sort correctly.

**Alternative.** Scan the `Flight.bootstrap(modules:)` call for the roots.
Exact, and brittle: several call sites, test harnesses among them.

---

## D1 — `@Scheduler` maps to the `component` stereotype

**Chosen.** The manifest reports `@Scheduler` types as `component`.

**Why.** `Stereotype` has no scheduler case, and the macro passes no
`stereotype:` argument, so `.component` is what the runtime records.
Inventing a case in a build tool would put the manifest and the runtime out
of step.

**Alternative.** Add `Stereotype.scheduler` and have both use it — a small,
real improvement to Actuator's grouping, and a change to a Core enum that
this work did not need.
