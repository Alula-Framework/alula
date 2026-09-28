# Subtraction Inventory

Pass 1 of the subtraction audit: what Alula exposes today, measured at
alula 0.59.0 (46bdab3, 2026-09-28). Nothing here changes code. The decisions
are in [subtraction-recommendations.md](subtraction-recommendations.md).

Usage counts come from four consumers: alula-data, the alula-cli templates
(skeleton, basics, demo, `_auth`), the Fledge tutorial, and Relay. A count
of 0 means none of the four uses it.

## Headline numbers

| Metric | Count |
|---|---|
| Library products | 37 (+ 1 plugin product) |
| Products no consumer uses | 4: AlulaConfigCore, AlulaPresenceProtocol, AlulaCronCore, AlulaSchedulerTesting |
| Products that exist only because of internal decomposition | 5: the four above, plus AlulaConfig (reached through AlulaCore's re-export) |
| Targets | 71: 40 library, 26 test, 3 macro, 1 executable, 1 plugin, plus CArgon2 and CAlulaZlib |
| Products a new HTTP app must list | 2 minimum (AlulaWeb **and** AlulaTransport). Templates list 4: Core, Web, Transport, Actuator |
| Traits | 7: default (empty), Web, Security, HTTPClient, SMTP, APNS, Telemetry |
| Public macros | 17 (no property wrappers) |
| Macros that expand identically | 3: `@Component`, `@Service`, `@Repository` |
| Semantic magic comments | 3: `alula:hand-registered`, `alula:module-registered`, `alula:undocumented-response` |
| Testing products | 10 in alula (+ 2 in alula-data). No umbrella |
| Runtime developer endpoints | 5 Actuator routes + `/openapi.json` |
| Compatibility shims (API) | 3 deprecated declarations, all unused |
| Config-key aliases | 4 families: `pubsub.*` snake_case, `alula.presence.*`, `alula.channels.*`, `security.oidc.*` snake_case |
| Swift lines in Sources | 49,964; the largest file is the generator's `main.swift` at 3,720 |
| Package.swift | 1,131 lines, no helper functions |

## 1. Products

**Class** means: **U** = a normal app imports it; **A** = advanced or
optional (an extension point, a client, tests); **I** = exists only for
internal decomposition.

| Product | Trait | Used by (data / templates / fledge / relay) | Class | Note |
|---|---|---|---|---|
| AlulaCore | — | all four | U | Listed everywhere, though AlulaWeb already depends on it |
| AlulaWeb | Web | templates, fledge, relay | U | |
| AlulaTransport | Web | templates, fledge, relay | U | **Every** HTTP app lists it; nothing pulls it in |
| AlulaActuator | Web | templates, fledge, relay | U | |
| AlulaConfig | — | 1 stray relay import | I | Re-exported by AlulaCore |
| AlulaConfigCore | — | none | I | Re-exported by AlulaConfig; used by the generator and macros |
| AlulaDiagnostics | — | alula-data, alula-cli | A | Tooling and package authors |
| AlulaOpenAPI | Web | templates, relay | A | |
| AlulaPubSub | — | data, templates, relay | U / A | Also alula-data's adapter seam |
| AlulaChannels | Web | templates, fledge, relay | U | |
| AlulaChannelsProtocol | — | templates, fledge, relay list it | I | Re-exported by Channels and ChannelsClient; listed redundantly |
| AlulaChannelsClient | — | templates, fledge, relay | A | Swift client |
| AlulaChannelsTransport | Web | relay | A | Client WebSocket with headers |
| AlulaPresence | Web | templates, fledge, relay | U | |
| AlulaPresenceProtocol | — | none | I | Re-exported by Presence |
| AlulaPresenceClient | — | templates | A | |
| AlulaSessions | — | alula-data | A | Store seam; apps get it through AlulaWeb's re-export |
| AlulaRateLimit | — | data, templates, relay | A | Store seam |
| AlulaScheduler | — | data, templates, fledge, relay | U | |
| AlulaCronCore | — | none | I | Re-exported by Scheduler; shared with its macro |
| AlulaQueue | — | data, templates, relay | U | |
| AlulaMail | — | templates, fledge, relay | U | |
| AlulaMailSMTP | SMTP | relay | A | |
| AlulaHTTPClient | HTTPClient | relay | A | |
| AlulaSecurityCore | Security | templates, fledge, relay | U | |
| AlulaAPNS | APNS | relay | A | |
| AlulaTelemetryBridges | Telemetry | relay | A | Mostly pulled in transitively |
| `*Testing` (10) | various | see §5 | A | |

The 9 non-test targets with no product: AlulaMacroSupport, AlulaRouteScan,
CArgon2, CAlulaZlib, the 3 macro implementations, `alula-registration-gen`,
and the plugin.

**Re-exports:**

| Module | Re-exports |
|---|---|
| AlulaCore | AlulaConfig |
| AlulaConfig | AlulaConfigCore |
| AlulaWeb | AlulaSessions and four HTTPTypes types |
| AlulaChannels, AlulaChannelsClient | AlulaChannelsProtocol |
| AlulaPresence | AlulaPresenceProtocol |
| AlulaScheduler | AlulaCronCore |

Nothing re-exports AlulaTransport.

## 2. The web import path

A new app lists AlulaWeb and AlulaTransport, then names the transport in
`Main.swift`: `AlulaWebModule<AlulaTransport>.self`.
- The `Web` trait enables AlulaTransport's dependencies but cannot add the
  product.
- AlulaTransport depends on AlulaWeb, not the reverse.

Drift found and fixed during this pass:
- The README's first snippet had no `traits: ["Web"]` and failed with
  AlulaWeb's trait guard.

Drift found, still open:
- The README's traits table omits `HTTPClient` and `SMTP`.
- The demo template's comment about "defaults" is stale.

## 3. Macros and annotations

| Macro | Expansion | Used by apps? |
|---|---|---|
| `@Component` | memberwise `init` over `@Inject`/`@ConfigValue` | 0 declarations in any app |
| `@Service` | **identical** to `@Component`; descriptor tagged `.service` | 29 types |
| `@Repository` | **identical**; tagged `.repository` | 2 types |
| `@Inject(from:)`, `@ConfigValue` | empty markers | yes |
| `@Settings` + `@Secret` | `init` binding `namespace.kebab-key`, redacted `description` | fledge only |
| `@Controller` | `@Component`'s `init` (a separate copy) + route factories | yes |
| `@Middleware` | `@Component`'s `init` (a copy) + conformance | rare |
| `@Get/Post/Put/Patch/DeleteRoute`, `@WebSocketRoute` | one shared marker implementation | `@PutRoute` is used nowhere |
| `@Scheduler` / `@Scheduled` | `init` (a copy) + jobs function / marker | yes |

The stereotype tag is read only by Actuator's dashboard grouping and JSON,
and by the generator for two cases:
- `controller`: left out of the graph unless something depends on it;
- `settings`: passes configuration to the `init`.

There is a dead generator check: `containerConstructed = ["scheduler"]`
never matches, because no attribute maps to a `scheduler` stereotype.

## 4. Magic comments

| Directive | Effect | Real uses |
|---|---|---|
| `// alula:hand-registered` | On an `@Inject`, the generator stops treating the type as needing a scanned provider. In an **application** target the warning it silences no longer fires. What remains is: skipping bridge synthesis for `any P`, and skipping the optional-`?` check | 1 in alula; 8 in templates, 13 in fledge, 24 lines in relay. Mostly vestigial |
| `// alula:module-registered` | On a type, it is excluded from generated registrations and the graph | 2, both in AlulaSecurityCore. Framework-only |
| `// alula:undocumented-response` | Silences the opt-in ALU-OAPI-3002 for one route | 0 real uses |

All three are matched by substring on the surrounding trivia, so a mention
in prose also triggers them.

## 5. Testing

- **10 testing products:** Web, Sessions, RateLimit, Queue, Mail, Channels,
  PubSub, Scheduler, HTTPClient, APNS. They are small, from 40 to 520 lines;
  AlulaWebTesting is the largest.
- **Usage:** about half of all app test files import two or three of them
  together (Web+Sessions, Web+Queue(+Mail), Web+Channels).
- **Declared but never imported:** the demo template declares 7, including
  PubSubTesting. Relay declares 7, including WebTesting and SessionsTesting.
- **Undocumented:** `Docs/testing.md` does not mention the Mail, Queue,
  RateLimit, Scheduler, APNS or HTTPClient testing modules.

## 6. Runtime endpoints and CLI

| Endpoint | Static or runtime | Gate |
|---|---|---|
| `/actuator/health`, `/live`, `/ready` | runtime | always, unless disabled |
| `/actuator` dashboard | mixed: the component list is static (build-scanned); health and checks are runtime | `full` exposure only (explicit dev/test env) |
| `/actuator/info` | mostly static (config) + uptime | `full` only |
| `/openapi.json` | static | on in dev/test |

There is no runtime route listing and no metrics route.

CLI commands: `new`, `migrate`, `routes` (static; controller routes only),
`dev`, `run`, `generate controller|auth`, `explain`.

Inconsistencies:
- Under `alula dev`, which sets no `ALULA_ENV`, OpenAPI is on but the Actuator
  dashboard is off.
- The skeleton's `alula.yaml` mentions a metrics endpoint that doesn't exist.

## 7. Composition API

| Name | What it is |
|---|---|
| `dependencies` | The only declared module edge |
| `includedModules` | Generator output: the transitive closure of `dependencies` from the `modules:` list. Nobody implements it |
| `defaultProviders` | Consulted only on ambiguity |
| `service`, `serviceShutdownPhase`, `serviceCompletion`, `commands`, `lifecycleHooks` | Module requirements with defaults |
| `routes`, `middleware` | Stored properties matched by type |

Drift found and fixed: `Docs/core.md` showed `static let includedModules` in
an app module, which the generator ignores. It now uses `dependencies`.

Nine fledge modules declare an empty `dependencies` that restates the
default.

## 8. Convenience overlap

| Task | Variants | Verdict |
|---|---|---|
| Startup | `Alula.run` (canonical), `assemble` (tests), `bootstrap` (alula's own tests) | Low redundancy |
| Routes | macros (canonical), `RouteRegistration` values, mounts (uploads, assets, `socketRoute`) | Values and mounts are distinct capabilities, but `alula routes` doesn't list them |
| Config | `get`, `get(_:default:)`, `getIfPresent`, `getIfPresent(_:formerly:)`, `@ConfigValue`, `@Settings` | `getIfPresent ?? x` and `get(_:default:)` overlap. `@Settings` is used by no app |
| Responses | return the value (uses the app's configured encoder); `.json(x, status:)` (uses the **default** encoder) | 24 `.json` calls in apps, all just to set a status. A trap, not a bug |
| Queue | `enqueue`, `prepare` + `store.enqueue(_:in:)` | Relay wrote its own `DurableWork.enqueue(_:options:in:)` because no single transactional call exists |
| Tests | `TestClient(routes: X.alulaRoutes {…})` (canonical), `alulaRoutes(graph)`, `RequestContext.mock`, `Alula.assemble`, `InMemoryTransport` | Distinct levels. Templates mix the first two |
| Actuator | four public `init`s; only `init(configuration:)` reads `actuator.format` | Redundant |

## 9. Compatibility debris

| Item | Status |
|---|---|
| `ConnectionUpgradeHandler`, `UpgradedConnection` typealiases (deprecated 0.4.0) | Unused anywhere. A misplaced doc comment sits beside them |
| `APNSError.deviceTokenIsInvalid` (deprecated 0.33.0) | Unused |
| Config aliases: `pubsub.node_id`/`broadcast_timeout`, `alula.presence.*` (7), `alula.channels.*` (5), `security.oidc.*` snake_case | Only alula's own tests use the old spellings. alula-data's `data-postgres.md:261` still documents `alula.channels.write-timeout-seconds` |
| `getIfPresent(_:formerly:as:)` | Public mechanism for module authors; stays |
| `FLIGHT_*` / `flight*.yaml` refusal, ALU-CONFIG-5012, `ConfigPrefix("flight")` | Deliberate D45 guard. **Keep, frozen** |
| NFKC legacy password verification | Persisted data (0.31/0.32 hashes). **Keep** |
| `web.errors.format: simple` | Opt-in wire format. Keep |
| alula-data's `flight-migrate:v1`, the `FLIGHTMG` lock, `flight_migrations` | **Keep, frozen** (D45) |

## 10. Repository root

| Path | State |
|---|---|
| README, CHANGELOG, CONTRIBUTING, Docs/, Diagnostics/ | Current |
| DECISIONS.md | Current ADR log (D1–D58). Its line 3 still frames it as COMPOSITION-MIGRATION's log |
| GAPS.md (701 lines) | Stale. "Reconciled at v0.20.0"; mixes eras. Its live part is "Open, ranked" and §3–§5. Nothing links to it |
| COMPOSITION-MIGRATION.md | **Untracked** (gitignored), a finished spec. Yet 19 source comments cite it, 4 of them wrongly (§9 does not exist; D11 and D15 are DECISIONS entries) |
| `docs/` (lowercase) | Untracked DocC output from 2026-09-23 |
| `Benchmarks/` | Untracked leftover (`.build` only), moved to swift-telemetry |

## 11. Manifest and duplication

**Package.swift:**
- 52 no-op `swiftLanguageMode(.v6)` lines, applied to only 52 of 71 targets.
- 137 trait conditions.
- 31 swift-syntax product lines: three identical 5-line macro blocks and
  three identical 3-line macro-test blocks.
- 20 `Logging` lines and 16 `ServiceLifecycle` lines.
- 69 of 71 paths follow `Sources|Tests/<Group>/<Name>`.
- 15 `TraitGuard.swift` files.

**The same rule implemented more than once** (✱ = the copies have drifted
into different behaviour):

| Rule | Copies |
|---|---|
| ✱ `@Inject` collection and attribute-argument helpers | Component, Controller, Middleware, Scheduler, plus the generator. AlulaMacroSupport was meant to hold these; Scheduler differs on `static` and on `package` access |
| ✱ registration access modifier | 6 |
| Capped exponential backoff | Queue, HTTP client, Channels client (different jitter each) |
| `Retry-After` seconds rounded up | 3 |
| `Duration` → seconds | 8 copies under 4 names. **5 sites truncate fractions of a second** |
| ✱ "must be positive" config checks | about 15, across 19 error types. **`web.request-timeout-seconds: inf` passes the check, then crashes at startup** |
| Legacy-key fallback | 14 call sites |
| base64url | 5 encoders |
| Secure random token | 6 |
| SHA-256 → base64url | 3 |
| Constant-time compare | 2 |
| ✱ OAuth client auth and form encoding | 2; one leaves non-ASCII letters unencoded |
| ✱ URL redaction for logs | 3; the WebSocket copy keeps credentials |
| ✱ loopback check | 2; APNs is case-sensitive and misses `[::1]` |
| HTTP-date parsing | 2; one builds a `DateFormatter` per call |
| ✱ bounded expiring maps | 3; the one-time-token store sorts on every put when full |

Checked and found **not** to be duplicates: failure reports, bearer parsing
(already consolidated), HMAC, lifecycle state machines, periodic loops, and
the test clocks (similar, but Date vs monotonic time).
