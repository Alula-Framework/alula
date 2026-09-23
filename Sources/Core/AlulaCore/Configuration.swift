/// Alula Config's `Configuration`, re-exported.
///
/// This file was the placeholder seam while Alula
/// Config was a separate, not-yet-built package. The real package now lives
/// at `Config/alula-config` and Core depends on it; as designed, the seam
/// swap changed no Core API — `bootstrap(configuration:)`'s signature and the
/// `@ConfigValue` expansion still target exactly this surface.
///
/// The re-export means app targets `import AlulaCore` and get the whole
/// config API (sources, loader, errors, `AlulaEnvironment`) without a
/// second import. The typealias keeps `AlulaCore.Configuration` — the
/// module-qualified name macro-generated code uses so expansions resolve in
/// any client module — pointing at the one real type.
@_exported import AlulaConfig

public typealias Configuration = AlulaConfig.Configuration
