// Compile-time guard: this target exists only when the "Security" trait is on.
// Both traits are opt-in — Package.swift declares `.default(enabledTraits: [])`
// — so this fires for any consumer that did not name "Security", and for a root
// build without --enable-all-traits. The comment used to describe the
// opposite polarity, which would have made the guard look like a corner case
// rather than the default path.
#if !Security
#error("""
    AlulaSecurityCore requires the "Security" trait.

    Consuming alula:
        .package(url: "https://github.com/Alula-Framework/alula.git", \
                 from: "0.18.0", traits: ["Security"])

    Building alula itself:
        swift build --enable-all-traits
    """)
#endif
