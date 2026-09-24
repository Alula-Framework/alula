// Compile-time guard: this target exists only when the "SMTP" trait is on.
#if !SMTP
#error("""
    AlulaMailSMTP requires the "SMTP" trait.

    Consuming alula:
        .package(url: "https://github.com/Alula-Framework/alula.git", \
                 from: "0.39.0", traits: ["SMTP"])

    Building alula itself:
        swift build --enable-all-traits
    """)
#endif
