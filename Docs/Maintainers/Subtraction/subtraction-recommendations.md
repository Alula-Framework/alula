# Subtraction Recommendations

Pass 2 of the subtraction audit. Each candidate from
[subtraction-inventory.md](subtraction-inventory.md) is classified KEEP,
REMOVE, MERGE, HIDE, RELOCATE, RENAME or INVESTIGATE.

**The standing rule:** a removal must say where its capability lives
afterwards. If nothing covers it, the change is reshaped or dropped, not
shipped.

**Passes:**
- **Pass 3:** safe and mechanical. It does not break a consumer, or breaks
  only something nobody uses.
- **Pass 4:** API changes, made one at a time, each with tests, docs and the
  full suite.
- **Pass 5:** a design note only, with no implementation.

## Decided already

| # | Candidate | Class | Capability preserved by | Pass |
|---|---|---|---|---|
| R14 | Old config-key spellings | **Refuse at startup** (user decision, 2026-09-28): a coded diagnostic names the new key. There is no silent fallback and no dual reading | The new keys; the refusal tells the operator exactly what to rename | 4 |
| R5 | Web transport | **AlulaWeb product includes AlulaTransport** (user decision, 2026-09-28) | — | 4 |
| R26 | Testing | **AlulaTesting umbrella** (user decision, 2026-09-28) | — | 4 |
| R1 | `@Component` | **REMOVE** (user decision, 2026-09-28) | `@Service`, which expands identically and becomes the one general graph annotation. `@Component` stays one release as `@available(*, unavailable, renamed: "Service")`, so the editor offers the fix-it | 4 |

## Products

| # | Candidate | Class | Capability preserved by | Migration | Pass |
|---|---|---|---|---|---|
| R2 | AlulaConfigCore, AlulaCronCore, AlulaPresenceProtocol products | **HIDE** (drop the product; the target stays) | Re-exports from AlulaConfig, AlulaScheduler and AlulaPresence. The macros and generator depend on the targets directly | None: zero consumers | 3 |
| R3 | AlulaConfig product | **HIDE** | AlulaCore re-exports it | None: no consumer manifest lists it | 3 |
| R4 | AlulaChannelsProtocol product | **HIDE** | Re-exported by AlulaChannels (server) and AlulaChannelsClient (client). A Swift client depends on ChannelsClient, not the bare protocol | Templates, fledge and relay delete one redundant manifest line | 4 |
| R5 | Web needing two products (AlulaWeb + AlulaTransport) | **MERGE**, via a multi-target product: `.library(name: "AlulaWeb", targets: ["AlulaWeb", "AlulaTransport"])` | The ServerTransport seam is unchanged. A custom transport is still a peer, and AlulaTransport stays a separate *target*. The AlulaTransport *product* is kept one release for existing manifests | Apps drop one product line. `Main.swift` still imports AlulaTransport and names `AlulaWebModule<AlulaTransport>`. Getting rid of that too needs a design note (a default-transport typealias), so it's Pass 5 | 4 |
| R6 | AlulaCore listed next to AlulaWeb in templates | **REMOVE** from templates | AlulaWeb depends on it | Templates only | 4 |
| R7 | Client SDK as a separate package | **KEEP** in this repo | R2 and R4 already hide the protocol products. A split adds cross-repo protocol versioning, and the 2026-09-25 repo-split analysis found modules co-change with core at 50% or more | — | 5 (note only) |

## Root and documents

| # | Candidate | Class | Detail | Pass |
|---|---|---|---|---|
| R8 | Untracked local `Benchmarks/` and `docs/` | **REMOVE** (locally; not in git) | `docs/` is CI output and is regenerated | 3 |
| R9 | 19 source comments citing the untracked COMPOSITION-MIGRATION.md | **REWRITE** | Point each at the DECISIONS entry it means, or state the reason inline; fix the 4 wrong ones (§9, D11, D15) | 3 |
| R10 | GAPS.md | **RELOCATE + trim** | Move the live "Open, ranked" and §3–§5 items to `Docs/Maintainers/GAPS.md`, re-measured against 0.59. The postmortem history is already in CHANGELOG and DECISIONS. Keep the "GAPS.md §0 gap #N" citations meaningful by keeping the numbering, or pointing them to the tag | 3 |
| R11 | DECISIONS.md | **KEEP** at the root | Fix line 3's framing (it covers D1–D58, not one migration plan) | 3 |
| R12 | Doc drift: README traits table (no HTTPClient, SMTP), demo template's "defaults" comment, skeleton's "metrics" claim, alula-data's `alula.channels.*` key, the Upgrade.swift misplaced comment, the AuthenticationMiddleware stale `init(_alula:)` comment | **FIX** | — | 3 |

## Compatibility debris

| # | Candidate | Class | Capability preserved by | Pass |
|---|---|---|---|---|
| R13 | `ConnectionUpgradeHandler`, `UpgradedConnection`, `APNSError.deviceTokenIsInvalid` | **REMOVE** | Their replacements, named in each `renamed:`/message. Nothing uses them | 3 |
| R14 | Config-key aliases (`pubsub` snake_case, `alula.presence.*`, `alula.channels.*`, `security.oidc.*` snake_case) | **INVESTIGATE: user decision** | Deployment config is where to be conservative. Dropping an alias silently reverts a deployment's setting to its default. Options: (a) keep until 1.0; (b) replace the dual reading with a startup refusal naming the new key, like the D45 `FLIGHT_` guard; (c) remove outright. Recommended: **(b)**. It keeps the safety, drops the two-spellings semantics, and one shared helper replaces 14 call sites | 4 |
| R15 | `getIfPresent(_:formerly:as:)` | **KEEP** | Module authors' rename mechanism | — |
| R16 | D45 `flight` guards, NFKC password path, `web.errors.format: simple`, alula-data's frozen migration identifiers | **KEEP** (frozen, or persisted data / wire format) | — | — |

## Annotations and directives

| # | Candidate | Class | Capability preserved by | Pass |
|---|---|---|---|---|
| R17 | `@Repository` | **KEEP** | User decision: services and repositories are the two named roles | — |
| R18 | `// alula:module-registered` (2 uses, both in AlulaSecurityCore) | **REMOVE the directive** | Its two uses exist only to keep hand-constructed middleware out of the graph. Give `Authentication` and `RequireAuthentication` a hand-written `init`, and drop the registrable macro that made the directive necessary. No app ever needs it | 4 |
| R19 | `// alula:hand-registered` | **INVESTIGATE → likely REMOVE** | In app targets, the warning it silences no longer fires. Its remaining effects are skipping `any P` bridge synthesis and the optional-`?` check. Check each of the ~45 app sites for whether removing it changes the generated file. If none do, delete the directive from apps and docs. If some do, replace it with a typed marker on `@Inject` | 4 |
| R20 | `// alula:undocumented-response` (0 uses) | **REPLACE** with a typed route-macro argument, or remove together with the opt-in ALU-OAPI-3002 | It silences one route for an opt-in warning that no consumer turns on. A typed argument keeps the capability without comment syntax | 4 |
| R21 | Dead generator check `containerConstructed = ["scheduler"]` | **REMOVE** | Never matches | 3 |
| R22 | `@PutRoute` (unused), `@Settings` (unused by apps) | **KEEP** | Verb completeness; typed settings are a real capability | — |

## Composition

| # | Candidate | Class | Detail | Pass |
|---|---|---|---|---|
| R23 | `dependencies` vs `includedModules` | **KEEP** | Not two edges: `includedModules` is generator output. The only confusion was `Docs/core.md`, fixed in Pass 1 | — |
| R24 | 9 fledge modules declaring `dependencies: []` | **REMOVE** in fledge | Restates the default | 3 (fledge) |
| R25 | `AlulaModule.swift:11` "Not an ordering constraint" vs `:46-48` "orders modules by dependencies" | **FIX** | Say what is true: construction order comes from value flow, and `dependencies` breaks ties | 3 |

## Testing

| # | Candidate | Class | Capability preserved by | Pass |
|---|---|---|---|---|
| R26 | 10 testing products, no umbrella | **MERGE** into an `AlulaTesting` product: one target that re-exports the testing modules the enabled traits allow (`#if Web @_exported import AlulaWebTesting`, …) | The individual products stay for advanced and lean use. The umbrella's extra cost is compiling a few small modules (40–520 lines each). Test files go from 2–3 testing imports to one | 4 |
| R27 | `Docs/testing.md` covers half the modules | **FIX** alongside R26 | — | 4 |

## Runtime tooling

| # | Candidate | Class | Detail | Pass |
|---|---|---|---|---|
| R28 | Actuator dashboard's static component list | **KEEP** for now | The dashboard's health and checks are runtime, and it is gated to dev/test. Moving the component list to an `alula graph` command adds a feature to remove a small one, so a design note comes first | 5 |
| R29 | OpenAPI vs Actuator environment gates disagree | **FIX** | One rule for both: "an unset `ALULA_ENV` is dev" or "is not dev", decided once | 4 |
| R30 | Actuator's four public `init`s | **MERGE** to one or two | Only `init(configuration:)` reads `actuator.format`; the others are test conveniences | 4 |

## Convenience APIs

| # | Candidate | Class | Detail | Pass |
|---|---|---|---|---|
| R31 | `.json(x, status:)` uses the default encoder, not the app's | **FIX, no new API** | Dispatch binds the request's `WebCoders` in a task-local; `.json`'s default encoder reads it. The trap disappears and the signature is unchanged | 4 |
| R32 | `getIfPresent(...) ?? x` vs `get(_:default:)` | **KEEP both**, and name the canonical one in docs | Different contracts: the first is "absent is a value", the second "absent means this default" | — |
| R33 | Transactional enqueue: Relay built `DurableWork.enqueue(_:options:in:)` | **NOTE** (it's an addition, not a subtraction) | Candidate for alula-data: `PostgresQueueStore.enqueue(_:options:in:)` taking the job directly | later |

## Manifest and internal duplication

| # | Candidate | Class | Detail | Pass |
|---|---|---|---|---|
| R34 | 52 no-op `swiftLanguageMode(.v6)` lines | **REMOVE** | Tools-version 6.3 already defaults to Swift 6 mode; add it once in the existing post-loop if explicitness is wanted | 3 |
| R35 | Repeated swift-syntax, Logging and ServiceLifecycle product lines | **MERGE** into `let` constants | No DSL, only named constants | 3 |
| R36 | `@Inject` collection and argument helpers copied into Component, Controller, Middleware and Scheduler | **MERGE** into AlulaMacroSupport | This is what AlulaMacroSupport was for. It also fixes Scheduler's divergence on `static` and `package` | 3 |
| R37 | Same-rule helpers: base64url, secure random, constant-time compare, SHA-256 digest, `Duration` → seconds, `Retry-After` rounding, HTTP-date, loopback, URL redaction, form encoding, bounded expiring map, capped backoff | **MERGE** into one internal, dependency-free target (no product) | Each drifted copy gets fixed on the way: the five truncating `Duration` sites, the WebSocket redaction that keeps credentials, the APNs loopback check, non-ASCII form encoding, the one-time-token store sorting on every put | 3 |
| R38 | Hand-written "must be positive" checks and 19 error types | **MERGE** into `Configuration.positive(...)` helpers | Fixes `web.request-timeout-seconds: inf` crashing at startup. The per-module error types can stay; the message comes from the helper | 3 |
| R39 | 15 `TraitGuard.swift` files | **KEEP** | 8 lines each; their message names the missing trait, which a normal build does not | — |

## Order of work

1. **Pass 3.** R2, R3, R8–R13, R21, R24, R25, and R34–R38. The bugs found in
   R37 and R38 get regression tests.
2. **Pass 4**, one change per commit, each with the full suite, DocC and
   docs:
   1. R1 `@Component`
   2. R4, R5 and R6, the product path
   3. R26 and R27, testing
   4. R31, R29 and R30
   5. R18, R19 and R20, the directives
   6. R14, once decided
3. **Pass 5:** design notes for R5's `Main.swift` step, R7 and R28.
