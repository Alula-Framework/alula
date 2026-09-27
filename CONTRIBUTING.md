# Contributing

Thanks for your interest in Alula.

## Getting set up

```bash
swift build --enable-all-traits
./CI/run-tests.sh          # swift test --enable-all-traits, plus a summed count
```

The heavier dependencies are gated by traits — `Web`, `Security`,
`HTTPClient`, `SMTP`, `APNS`, `Telemetry` — and no trait is on by default. Build and test
with `--enable-all-traits`, as CI does, so every gated dependency is resolved;
what a consumer with no traits gets is checked separately (below). The suite
needs no services: the one suite that
talks to a real identity provider runs only when `ALULA_TEST_KEYCLOAK_URL` is
set (CI starts Keycloak with `CI/keycloak/start.sh`). The generator tests build
and invoke the real `alula-registration-gen` executable, so the first run takes
a little longer.

## Before opening a pull request

These are the CI gates, in the order CI runs them:

```bash
./CI/check-traps.sh                                   # every trap in runtime code has a listed reason
ALULA_STRICT_WARNINGS=1 swift build --enable-all-traits
./CI/run-tests.sh
./CI/check-lean-consumer.sh                           # a consumer with no traits still builds
./CI/check-versioned-consumer.sh                      # ...and resolves Alula by version
./CI/check-generated-compiles.sh                      # generated registration code compiles
swift format lint --recursive --strict Sources Tests  # advisory in CI
python3 CI/check-diagnostic-quotes.py --docs README.md Docs Diagnostics Sources --source ALU=Sources
```

The last one fails when documentation quotes a diagnostic whose wording has
since changed: every run of three or more fixed words in a quoted
`[ALU-…]` message must still appear in `Sources`.

The documentation job builds every DocC catalog with `--warnings-as-errors`;
run it as `.github/workflows/ci.yml`'s `docs` job does, with
`ALULA_BUILD_DOCS=1` and the same `--target` list. A dangling symbol link, an
undocumented parameter or a cross-module ``double-backtick`` link fails it.

The consumer checks and the docs plugin rewrite `Package.resolved` and
`CI/lean-consumer/Package.resolved`; revert them rather than committing the
churn.

### Diagnostics

A framework-owned error has a stable code (`ALU-DI-1001`) and a page in
`Diagnostics/`. Adding one means adding the code to `DiagnosticCode`, a page,
and a test that asserts the code; the catalog tests check all three agree.

```bash
ALULA_REGENERATE_DIAGNOSTICS=1 swift test --enable-all-traits --filter AlulaDiagnosticsTests
ALULA_UPDATE_GOLDEN=1 swift test --enable-all-traits --filter "GeneratorTests/golden"
```

The first regenerates `Catalog.generated.swift` from the pages. The second
re-records the generator's golden output; read the diff before committing it,
because a golden file is the message a developer will see.

## What governs decisions here

**Other packages build on this one.** alula-data, the alula-cli templates and
every application depend on these APIs, so an API change here is an API change
everywhere. Source-breaking changes are cheap now and very expensive after
1.0 — if something is wrong, the time to say so is before the tag.

**Failures belong at build time, then startup, then never at request time.**
The build plugin catches what it can as coded diagnostics, and eager
construction at composition catches the rest during startup — every component
is built once, up front, so nothing is left to fail for wiring reasons at
request time.

**Composition will not wire a data race.** A singleton is shared across every
task in the process, so it must be `Sendable`, and the compiler enforces it.

**Traps are for programmer errors that cannot be recovered from.** Runtime code
may not crash on input, configuration or a dependency's state; every
`precondition`, `fatalError`, `try!` and force-unwrap left is listed in
`CI/trap-allowlist.txt` with the reason only a programming error reaches it.
A module whose initializer needs values traps if something constructs it from
its type alone rather than through the composition root. Recoverable conflicts
throw instead: a duplicate route or an undeclared lane fails the bootstrap with
a message.

## Testing

`AlulaCoreTests` covers composition, module ordering, bootstrap and what
`Alula.run` reports on exit. `AlulaCoreMacroTests` pins macro expansions as
fixtures — treat those as normative; if an expansion changes, that is an API
change.

`AlulaRegistrationGenTests` drives the generator end to end: a manifest in, a
generated file and diagnostics out, with the diagnostics pinned as golden files
under `Diagnostics/`. That is the contract a broken build would break, so test
it there rather than through internal functions.
