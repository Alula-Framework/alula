import Configuration
import AlulaConfigCore
import Foundation

/// The bootstrap entry point — steps 1–5 of the app-wide sequence, which are
/// Alula Config's entire contribution:
///
/// ```
/// 1. AlulaEnvironment.current()        — read ALULA_ENV
/// 2. Load alula.yaml                   — base layer (required)
/// 3. Load alula-{env}.yaml             — environment layer (optional file)
/// 4. Wrap the process environment       — env var layer
/// 5. Configuration(providers: [env, envFile, base]) — assembled, immutable
/// ```
///
/// Pure and synchronous — no async, no actor isolation, since this all runs
/// before any concurrent work exists in the app's lifetime. That is why the
/// files are read here and handed to `AlulaYAMLSnapshot` already parsed,
/// rather than going through `FileProvider`'s `async` initializer: a
/// synchronous bootstrap is worth more to Alula than reusing that one
/// initializer, and both paths end at the same snapshot type.
extension Configuration {

    /// The base layer's file name: shared defaults across all environments.
    public static var baseFileName: String { AlulaConfigFiles.base }

    /// The environment layer's file name for `environment`,
    /// e.g. `alula-prod.yaml`.
    public static func fileName(for environment: AlulaEnvironment) -> String {
        AlulaConfigFiles.environmentFile(for: environment)
    }

    /// Resolves the full layered configuration for the active environment.
    ///
    /// - Parameters:
    ///   - directory: Where the base and overlay files live. Defaults to the
    ///     process working directory — the deployment convention (config ships
    ///     next to the binary's launch point). A process launched from
    ///     somewhere other than the project directory — a container with a
    ///     different `WORKDIR`, a service manager — passes the directory
    ///     explicitly rather than relying on where it happened to start.
    ///   - prefix: The word every spelling derives from: `<prefix>.yaml`,
    ///     `<prefix>-{env}.yaml`, `<PREFIX>_ENV`, `<PREFIX>_SERVER_PORT`.
    ///     Defaults to `ConfigPrefix.default` — `alula`. Changing it moves
    ///     the base file out of reach of the build-time `@ConfigValue` key
    ///     check, which then warns rather than verifying; see `ConfigPrefix`.
    ///   - environment: Overrides environment resolution. Defaults to nil,
    ///     meaning `ALULA_ENV` is read from `processEnvironment` —
    ///     the one place in an app's lifetime that variable is consulted.
    ///   - processEnvironment: The variables backing the env-var layer,
    ///     `ALULA_ENV` resolution, and `${VAR}` substitution. Defaults to
    ///     the real process environment; tests pass a dictionary, which
    ///     makes the entire load reproducible without touching global state.
    ///   - secrets: Which environment variables hold secrets. Marked values
    ///     are redacted in access logs and in provider descriptions — so a
    ///     dumped provider stack shows `ALULA_DATASOURCE_PASSWORD=<REDACTED>`.
    ///     Defaults to `.none`, preserving the previous behavior exactly.
    ///   - accessReporter: Receives an event per resolved key, from Alula's
    ///     own accessors as well as from `Configuration.reader`. Pass an
    ///     `AccessLogger` to log every config read at startup.
    ///   - additionalProviders: Extra providers, inserted *above* the env-var
    ///     layer so they win. The hook for sources this package defers —
    ///     Kubernetes secret directories, remote stores, CLI arguments.
    ///
    /// - Throws: `ConfigLoadError.missingBaseFile` when `alula.yaml` is
    ///   absent from `directory`, and the other `ConfigLoadError` cases for
    ///   files that exist but cannot be read or parsed.
    ///
    /// - Returns: The immutable `Configuration`, precedence-ordered
    ///   env vars → `alula-{env}.yaml` → `alula.yaml`, ready to hand to
    ///   `Alula.bootstrap(configuration:modules:)`.
    public static func load(
        from directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        prefix: ConfigPrefix = .default,
        environment: AlulaEnvironment? = nil,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        secrets: SecretsSpecifier<String, String> = .none,
        accessReporter: (any AccessReporter)? = nil,
        additionalProviders: [any ConfigProvider] = []
    ) throws -> Configuration {
        if prefix == .default {
            try refusePreRenameConfiguration(
                in: directory, processEnvironment: processEnvironment,
                environmentIsExplicit: environment != nil)
        }

        // Step 1 — the single <PREFIX>_ENV read.
        let active = environment
            ?? AlulaEnvironment.current(from: processEnvironment, prefix: prefix)
        let substitution = EnvironmentSubstitutionPolicy.resolve(processEnvironment)
        let fileManager = FileManager.default

        // Step 2 — base layer, required.
        let baseURL = directory.appendingPathComponent(prefix.baseFileName)
        guard fileManager.fileExists(atPath: baseURL.path) else {
            throw ConfigLoadError.missingBaseFile(expectedPath: baseURL.path)
        }
        let base = try yamlProvider(contentsOf: baseURL, substitution: substitution)

        // Step 3 — environment layer, optional. A missing file is not an
        // error: an environment need not override anything.
        let environmentURL = directory.appendingPathComponent(
            prefix.environmentFileName(for: active))
        let environmentLayer: (any ConfigProvider)? = fileManager.fileExists(atPath: environmentURL.path)
            ? try yamlProvider(contentsOf: environmentURL, substitution: substitution)
            : nil

        // Step 4 — env var layer. `prefixKeys(with:)` reproduces the
        // documented transform exactly: the provider joins components with `_`
        // and uppercases, so `datasource.pool_size` under a `alula` prefix
        // encodes to ALULA_DATASOURCE_POOL_SIZE — and under `myapp`,
        // MYAPP_DATASOURCE_POOL_SIZE.
        //
        // `ConfigKey([...])` — the components initializer — rather than the
        // String one, which dot-decodes. A prefix cannot contain a dot today,
        // but taking the components form means it is one component by
        // construction rather than by the validation happening to forbid it.
        let variables = EnvironmentVariablesProvider(
            environmentVariables: processEnvironment,
            secretsSpecifier: secrets
        ).prefixKeys(with: ConfigKey([prefix.rawValue]))

        // Step 5 — assemble, highest precedence first.
        var providers: [any ConfigProvider] = additionalProviders
        providers.append(variables)
        if let environmentLayer {
            providers.append(environmentLayer)
        }
        providers.append(base)
        return Configuration(
            providers: providers, environment: active, prefix: prefix,
            accessReporter: accessReporter
        )
    }

    /// Throws ``ConfigLoadError/preRenameConfiguration(variables:files:)``
    /// when a deployment still carries the framework's pre-rename spellings.
    ///
    /// Two signals only, both specific enough not to catch an application's
    /// own names: `FLIGHT_ENV` (unless `ALULA_ENV` is set, or the environment
    /// is passed explicitly — either says the deployment has moved), and a
    /// `flight.yaml` or `flight-<env>.yaml` in the configuration directory.
    /// Once either fires, every other `FLIGHT_*` variable is listed too, since
    /// each is an override that would otherwise be dropped without a word.
    private static func refusePreRenameConfiguration(
        in directory: URL,
        processEnvironment: [String: String],
        environmentIsExplicit: Bool
    ) throws {
        let legacy = ConfigPrefix("flight")
        let staleEnvironment =
            !environmentIsExplicit
            && processEnvironment[legacy.environmentVariable].map { !$0.isEmpty } == true
            && processEnvironment[ConfigPrefix.default.environmentVariable] == nil
        let files =
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { name in
                name == legacy.baseFileName
                    || (name.hasPrefix("\(legacy.rawValue)-") && name.hasSuffix(".yaml"))
            }
            .sorted()
        guard staleEnvironment || !files.isEmpty else { return }
        let variables = processEnvironment.keys
            .filter { $0.hasPrefix("\(legacy.rawValue.uppercased())_") }
            .sorted()
        throw ConfigLoadError.preRenameConfiguration(variables: variables, files: files)
    }

    /// Reads one YAML layer from disk into an in-memory provider.
    ///
    /// The parse happens here, synchronously, and the resulting snapshot is
    /// wrapped in a provider that serves it — the same `AlulaYAMLSnapshot`
    /// a `FileProvider<AlulaYAMLSnapshot>` would build, minus the `async`.
    private static func yamlProvider(
        contentsOf url: URL,
        substitution: EnvironmentSubstitutionPolicy
    ) throws -> any ConfigProvider {
        let document = try AlulaYAMLDocument(contentsOf: url, substitution: substitution)
        return AlulaYAMLProvider(
            snapshot: AlulaYAMLSnapshot(document: document, providerName: url.lastPathComponent)
        )
    }
}
