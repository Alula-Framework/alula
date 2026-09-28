# Subtraction Changes

What the subtraction audit changed, and why. Each entry names the capability
the change touched and where that capability lives now. Item numbers
(R1–R39) refer to
[subtraction-recommendations.md](subtraction-recommendations.md).

## Pass 3 — safe and mechanical

### Products (R2, R3)

AlulaConfigCore, AlulaConfig, AlulaPresenceProtocol and AlulaCronCore are no
longer products; their targets are unchanged. That leaves 33 library
products, down from 37.

- **Capability:** every module is still reachable. AlulaCore re-exports
  AlulaConfig, which re-exports AlulaConfigCore. AlulaScheduler re-exports
  AlulaCronCore. AlulaPresence and AlulaPresenceClient re-export
  AlulaPresenceProtocol; the client's re-export is new, added because its
  public API returns `PresenceEntry` and `PresenceMeta`.
- **Consumers:** none of the four products appears in any consumer manifest
  (alula-data, alula-cli and its templates, fledge, relay).

### Manifest (R34, R35)

- Removed 55 `swiftSettings: [.swiftLanguageMode(.v6)]` entries. Tools-version
  6.3 already builds in Swift 6 mode, and `swift package dump-package` shows
  those settings were the only difference.
- The swift-syntax products for the three macro implementations and the
  three macro test targets are now two constants,
  `macroImplementationDependencies` and `macroTestDependencies`. Every target's
  dependency set is unchanged, checked against the dumped manifest.
- `Logging` and `ServiceLifecycle` were left as they are. A name for a
  one-line product reference would not make the manifest clearer.

### Macro machinery (R36)

`@Inject` collection, attribute-argument helpers, `registrationAccess` and
three validators moved into `AlulaMacroSupport/InjectionScanning.swift`.
The copies in Component, Controller, Middleware, Settings and Scheduler are
gone, including Scheduler's `Injection.swift`. That is 518 net source lines.

- **Capability:** every pinned macro expansion is byte-identical.
- **Divergences resolved, each pinned by a test:**
  - A `static` `@Inject` is now ALU-DI-1019 in all four macro families.
  - A `package` `@Scheduler` gets `package` access.
  - Scheduler scans the first binding, as the generator does.
  - Scheduler now reports an untyped `@Inject` (ALU-DI-1016) and a keyless
    `@ConfigValue` (ALU-CONFIG-5001), which it used to skip.

### Shared rules and their bugs (R37, R38)

Two internal targets now hold rules that were written several times:
- **`AlulaSupport`:** standard library only, so Foundation-free modules
  stay that way.
- **`AlulaSupportFoundation`:** the helpers that need Foundation.

Moved there: base64url, secure random bytes, constant-time compare,
`Duration` to seconds, rounded `Retry-After`, HTTP-date, loopback detection,
URL redaction for logs, OAuth form encoding and Basic auth, and bounded-map
eviction. Configured positive numbers are checked by
`Configuration.positive(...)`, `positiveSeconds(...)` and
`secondsOrDisabled(...)`.

- **Capability:** public API is unchanged. AlulaWeb's `HTTPDate` stays as a
  facade over the shared codec.
- **Bugs fixed on the way, each with a regression test:**
  - `web.request-timeout-seconds: inf` or `nan` crashed at startup. A finite
    `1e300` crashed the channels, presence and lifecycle intervals the same
    way.
  - Sub-second lifetimes were truncated to whole seconds in four places, so
    a value under a second expired on issue.
  - A WebSocket client error logged `user:password`.
  - APNs refused a plain-HTTP emulator on `[::1]` or `*.localhost`.
  - Non-ASCII OAuth credentials went out unencoded.
  - The in-memory one-time-token store sorted every record on each `put`
    once full.
- **Not merged: capped backoff.** The three implementations differ on
  purpose in type, truncation and jitter, and `RetryPolicy.baseDelay` is
  public and pinned to its arithmetic.

### Documents and dead code (R8–R13, R21, R25)

- **Removed:** the deprecated `ConnectionUpgradeHandler`, `UpgradedConnection`
  and `APNSError.deviceTokenIsInvalid`. Nothing used them; their
  replacements are the names the deprecations pointed to.
- **`GAPS.md` moved to `Docs/Maintainers/GAPS.md`,** keeping only the items
  still open. `git show v0.59.0:GAPS.md` has the history.
- **Source comments:** 14 comments cited the untracked
  `COMPOSITION-MIGRATION.md`. They now cite DECISIONS entries or give their
  reason inline.
- **Doc fixes:**
  - DECISIONS.md's opening now describes what it is.
  - The README's traits table lists all traits, and its first snippet
    builds.
  - `Docs/core.md` uses `dependencies`.
  - `AlulaModule`'s ordering docs say what is true.
- **Dead code:** the generator's `scheduler` check is gone. It never matched.
- **Local only:** the untracked `Benchmarks/` and `docs/` leftovers are
  deleted.
- **Format debt re-measured:** 4,267 violations. The figure it replaced,
  1,725, dated from 2026-09-18.

## Pass 4 — one change per commit

### `@Component` (R1)

`@Component` is removed. `@Service` is the one general "put this in the graph"
annotation, and `@Repository` stays beside it for data access.

- **Capability:** unchanged. `@Service` always expanded identically to
  `@Component`. The only difference was the stereotype tag in the scanned
  descriptor, and that tag changes from `.component` to `.service`.
  `Stereotype.component` stays as the bucket for graph nodes with no more
  specific tag, such as `@Scheduler` types, so Actuator's dashboard grouping
  is unchanged.
- **Migration:** for one release the declaration stays, marked
  `@available(*, unavailable, renamed: "Service")`. Any use is a compile error
  with a rename fix-it, and a test compiles a use to pin that. `ComponentMacro`
  stays in the plugin for that release. Without it, the compiler adds a second
  error because it cannot find the implementation.
- **Generator:** it no longer scans `@Component`. Its messages, the
  diagnostic pages, DocC and Docs now say `@Service`. No new rule restricts
  what a controller injects.

### `AlulaChannelsProtocol` product (R4)

The product is removed; the target stays.

- **Capability:** unchanged. `AlulaChannels` and `AlulaChannelsClient` both
  `@_exported import AlulaChannelsProtocol`, so `Envelope`, `JSONValue`,
  `ReservedEvent` and the error reasons arrive with either. Presence's protocol
  target still depends on the target directly. DocC still builds for it.
- **Migration:** delete the product line from the manifest. A file that
  imported `AlulaChannelsProtocol` imports `AlulaChannels` (server) or
  `AlulaChannelsClient` (client) instead.
- **Manifest:** a comment where the product was, like the ones for the hidden
  Config, PresenceProtocol and CronCore products.

### `AlulaWeb` product includes `AlulaTransport` (R5)

The `AlulaWeb` product is now `targets: ["AlulaWeb", "AlulaTransport"]`.

- **Capability:** unchanged. `AlulaTransport` is still its own target and
  still depends on `AlulaWeb`, not the reverse. `ServerTransport` is
  untouched, and a third-party transport is still a peer. A scratch consumer
  listing only `AlulaWeb` compiled and linked `import AlulaTransport`,
  `AlulaWebModule<AlulaTransport>.self` and a custom `ServerTransport`.
- **Migration:** delete the `AlulaTransport` product line. The product is kept
  for one more release so existing manifests resolve, marked in the manifest
  for removal in the release after next. SwiftPM accepts two products that
  share a target.
- **Docs:** the README's Getting started, `Docs/web.md`'s "Adding this
  module", and the manifest snippets in the sessions, security-core,
  presence, channels and actuator pages list `AlulaWeb` only.
- **Still open (Pass 5):** `Main.swift` still imports `AlulaTransport` and
  names it. Removing that needs a default-transport typealias and a design
  note.

### `AlulaCore` beside `AlulaWeb` (R6)

Docs only. The manifest snippets in `Docs/web.md`, `sessions.md`,
`security-core.md`, `presence.md`, `channels.md` and `actuator.md` no longer
list `AlulaCore` next to `AlulaWeb`.

- **Capability:** unchanged. `AlulaWeb` depends on `AlulaCore`, so
  `import AlulaCore` resolves with `AlulaWeb` alone; the R5 scratch consumer
  does exactly that. Pages whose snippet lists `AlulaCore` without `AlulaWeb`
  (scheduler, pubsub, apns, core) are unchanged.
- **Templates:** they live in alula-cli and are changed there.

### `AlulaTesting` umbrella (R26)

A new `AlulaTesting` product and target (`Sources/Testing/AlulaTesting`),
whose one file `@_exported import`s the testing modules.

- **Capability:** nothing removed. All ten `*Testing` products stay for lean
  or single-seam builds; the umbrella is only compiled when a package lists
  it.
- **Gating:** Mail, PubSub, Queue, RateLimit, Scheduler and Sessions testing
  are re-exported unconditionally. Web and Channels testing sit behind
  `#if Web`, HTTPClient testing behind `#if HTTPClient`, APNS testing behind
  `#if APNS`. Each matching dependency has the same `.when(traits:)`
  condition. A scratch `traits: []` consumer listing `AlulaTesting` built,
  ran its test, and resolved the same 7 packages as the lean consumer.
- **Coverage:** `AlulaTestingTests` imports only `AlulaTesting` and touches a
  type from every re-exported module, so CI compiles the umbrella. A one-page
  DocC catalog is in the docs job's target list.
- **alula-data's** testing modules are not included: they are another
  package's.

### `Docs/testing.md` module section (R27)

"Testing the layers" now opens with `import AlulaTesting` and a table of the
ten modules, what each gives a test, and the trait each needs, with a note on
when to list one module directly. New sections cover rate limiting, Queue and
Mail, the Scheduler, outbound HTTP and APNs, which the page had not
mentioned. The existing sections are kept.
