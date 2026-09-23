// Compile-time guard: this target exists only when the "Telemetry" trait is
// on — named directly, or through "Web" or "APNS", which imply it. The core,
// FlightTelemetry, needs no trait: any target may emit.
#if !Telemetry
    #error(
        """
        FlightTelemetryBridges requires the "Telemetry" trait ("Web" and "APNS" imply it).

        Consuming flight:
            .package(url: "https://github.com/Flight-Framework/flight.git", \
                     from: "0.34.0", traits: ["Telemetry"])

        Building flight itself:
            swift build --enable-all-traits
        """)
#endif
