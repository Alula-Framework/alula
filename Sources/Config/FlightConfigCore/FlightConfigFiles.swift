/// The config file names the layering is built from, at the default prefix.
///
/// These live in `FlightConfigCore` rather than beside `Configuration.load`
/// because Flight Core's `flight-registration-gen` build tool needs to find
/// `flight.yaml` to check `@ConfigValue` keys against it, and that tool links
/// only the dependency-free core. `Configuration.baseFileName` and
/// `Configuration.fileName(for:)` forward here, so both spellings agree by
/// construction.
///
/// Every name derives from ``ConfigPrefix/default``. An application using a
/// custom ``ConfigPrefix`` gets its names from that value instead — see
/// ``ConfigPrefix`` for what that means for the build-time key check.
public enum FlightConfigFiles {

    /// The base layer's file name at the default prefix: `flight.yaml`.
    public static let base = ConfigPrefix.default.baseFileName

    /// The environment layer's file name for `environment` at the default
    /// prefix, e.g. `flight-prod.yaml`.
    public static func environmentFile(for environment: FlightEnvironment) -> String {
        ConfigPrefix.default.environmentFileName(for: environment)
    }
}
