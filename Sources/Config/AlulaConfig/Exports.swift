/// `AlulaConfigCore` re-exported.
///
/// The package is split so that Alula Core's `alula-registration-gen` build
/// tool can link the parser without dragging swift-configuration (and its
/// transitive swift-system / swift-collections / swift-service-lifecycle) into
/// every consumer's build graph. That split is a build-graph concern and
/// should not be an import-statement concern: `import AlulaConfig` still
/// yields the whole API — `ConfigDecodable`, the error types,
/// `AlulaEnvironment`, the sources, the YAML parser — exactly as before, and
/// Alula Core's own `@_exported import AlulaConfig` keeps working unchanged.
@_exported import AlulaConfigCore
