// Compile-time guard: this target exists only when the "APNS" trait is on.
#if !APNS
#error("""
    AlulaAPNSTesting requires the "APNS" trait.

    Consuming alula:
        .package(url: "https://github.com/Alula-Framework/alula.git", \
                 from: "0.25.0", traits: ["APNS"])

    Building alula itself:
        swift build --enable-all-traits
    """)
#endif
