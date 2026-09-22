// Compile-time guard: this target exists only when the "APNS" trait is on.
// Both traits are opt-in — Package.swift declares `.default(enabledTraits: [])`
// — so this fires for any consumer that did not name "APNS", and for a root
// build without --enable-all-traits.
#if !APNS
#error("""
    FlightAPNS requires the "APNS" trait.

    Consuming flight:
        .package(url: "https://github.com/Flight-Framework/flight.git", \
                 from: "0.25.0", traits: ["APNS"])

    Building flight itself:
        swift build --enable-all-traits
    """)
#endif
