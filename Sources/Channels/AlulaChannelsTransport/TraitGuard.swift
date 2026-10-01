// Compile-time guard: this target exists only when the "Web" trait is on.
#if !Web
    #error(
        """
        AlulaChannelsTransport requires the "Web" trait.

        Consuming alula:
            .package(url: "https://github.com/Alula-Framework/alula.git", \
                     from: "0.62.0", traits: ["Web"])

        Building alula itself:
            swift build --enable-all-traits
        """)
#endif
