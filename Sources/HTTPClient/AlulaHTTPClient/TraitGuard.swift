// Compile-time guard: this target exists only when the "HTTPClient" trait is on.
#if !HTTPClient
#error("""
    AlulaHTTPClient requires the "HTTPClient" trait.

    Consuming alula:
        .package(url: "https://github.com/Alula-Framework/alula.git", \
                 from: "0.40.0", traits: ["HTTPClient"])

    Building alula itself:
        swift build --enable-all-traits
    """)
#endif
