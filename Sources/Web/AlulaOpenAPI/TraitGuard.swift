// Compile-time guard: this target exists only when the "Web" trait is on.
#if !Web
#error("""
    AlulaOpenAPI requires the "Web" trait.

        .package(url: "https://github.com/Alula-Framework/alula.git", \
                 from: "0.43.0", traits: ["Web"])
    """)
#endif
