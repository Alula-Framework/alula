Vendored from the Argon2 reference source code package:

    https://github.com/P-H-C/phc-winner-argon2
    commit f57e61e19229e23c4445b85494dbf7c07de721cb

The six files upstream's own `Package.swift` builds as its `argon2` library
product — `argon2.c`, `core.c`, `encoding.c`, `ref.c`, `thread.c`, and
`blake2/blake2b.c` — plus the headers those need (`include/argon2.h` is the
public one; the rest are private, alongside the sources that use them).
`genkat.h` is present but never compiled, the same as upstream's own
manifest: `core.c` includes it, but declares no call to anything it
declares. `opt.c` (the SIMD-accelerated variant, upstream's own manifest
excludes it too) is not vendored — `ref.c`, portable C with no
runtime CPU-feature detection, is the whole implementation here, and is
what a security-relevant C dependency should be: bounded, auditable, and
the same on every architecture Alula ships to.

Unmodified, verbatim, dual CC0-1.0/Apache-2.0 per `LICENSE` in this
directory — see D37 in alula's `DECISIONS.md` for why this is vendored
rather than an external SwiftPM package dependency: the package this came
from carries no semantic-version tags, so pinning it with `revision:`
made every one of alula's own tagged releases with the `Security` trait
enabled unresolvable by a consumer using an ordinary `from:` requirement,
SwiftPM refusing a version-pinned package's dependency on one that is not.
Vendoring the six files removes the external dependency, and with it the
requirement that broke.

To move to a newer upstream commit: `git clone` the repository above,
`git checkout` the revision wanted, and repeat the copy this directory's
history shows — the same six sources, the same headers, `LICENSE`
replaced if it changed, this file's commit line updated.
