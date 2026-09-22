// Compile-time guard: this target exists only when the "APNS" trait is on.
#if !APNS
#error("""
    FlightAPNSTesting requires the "APNS" trait.

    Consuming flight:
        .package(url: "https://github.com/Flight-Framework/flight.git", \
                 from: "0.25.0", traits: ["APNS"])

    Building flight itself:
        swift build --enable-all-traits
    """)
#endif
