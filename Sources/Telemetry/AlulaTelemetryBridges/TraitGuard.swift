// Compile-time guard: this target exists only when the "Telemetry" trait is
// on — named directly, or through "Web" or "APNS", which imply it. Emitting
// needs no Alula at all: that is swift-telemetry's TelemetryCore.
#if !Telemetry
    #error(
        """
        AlulaTelemetryBridges requires the "Telemetry" trait ("Web" and "APNS" imply it).

        Consuming alula:
            .package(url: "https://github.com/Alula-Framework/alula.git", \
                     from: "0.34.0", traits: ["Telemetry"])

        Building alula itself:
            swift build --enable-all-traits
        """)
#endif
