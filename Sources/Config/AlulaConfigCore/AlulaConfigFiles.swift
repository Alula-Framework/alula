/// The config file names the layering is built from, at the default prefix.
///
/// These live in `AlulaConfigCore` rather than beside `Configuration.load`
/// because Alula Core's `alula-registration-gen` build tool needs to find
/// `alula.yaml` to check `@ConfigValue` keys against it, and that tool links
/// only the dependency-free core. `Configuration.baseFileName` and
/// `Configuration.fileName(for:)` forward here, so both spellings agree by
/// construction.
///
/// Every name derives from ``ConfigPrefix/default``. An application using a
/// custom ``ConfigPrefix`` gets its names from that value instead — see
/// ``ConfigPrefix`` for what that means for the build-time key check.
public enum AlulaConfigFiles {

    /// The base layer's file name at the default prefix: `alula.yaml`.
    public static let base = ConfigPrefix.default.baseFileName

    /// The environment layer's file name for `environment` at the default
    /// prefix, e.g. `alula-prod.yaml`.
    public static func environmentFile(for environment: AlulaEnvironment) -> String {
        ConfigPrefix.default.environmentFileName(for: environment)
    }
}
