import Foundation

/// A `ConfigSource` backed by one Alula-subset YAML document — the shape of
/// precedence layers 2 and 3 (`alula-{env}.yaml`, `alula.yaml`).
///
/// Since the move onto swift-configuration the runtime path no longer goes
/// through this type: `Configuration.load` builds a
/// `FileProvider<AlulaYAMLSnapshot>` instead, and both wrap the same
/// `AlulaYAMLDocument`. It remains because it is public API, because a
/// `ConfigSource` is still the smallest possible way to hand-assemble a
/// `Configuration`, and because tooling that only wants a parsed file's keys
/// should not have to link a provider stack to get them.
public struct YAMLConfigSource: ConfigSource {

    /// The parsed document backing this source.
    public let document: AlulaYAMLDocument

    /// Diagnostic name — the file name for file-backed sources. Appears in
    /// every error this source produces.
    public var name: String { document.name }

    /// Every flattened key this source holds.
    public var keys: Set<String> { document.keys }

    /// Wraps an already-parsed document.
    public init(document: AlulaYAMLDocument) {
        self.document = document
    }

    /// Parses a YAML document from a string.
    ///
    /// - Parameters:
    ///   - string: The document text.
    ///   - name: Diagnostic name used in errors.
    ///   - substitution: How `${VAR}` placeholders are resolved. Defaults to
    ///     the process environment — the correct runtime behavior.
    public init(
        string: String,
        name: String = "<inline yaml>",
        substitution: EnvironmentSubstitutionPolicy = .processEnvironment
    ) throws {
        self.document = try AlulaYAMLDocument(
            string: string, name: name, substitution: substitution
        )
    }

    /// Reads and parses a YAML file. Whether a *missing* file is an error is
    /// the caller's policy, so this initializer only throws for files
    /// that exist but cannot be read or parsed — check existence first.
    public init(
        contentsOf url: URL,
        substitution: EnvironmentSubstitutionPolicy = .processEnvironment
    ) throws {
        self.document = try AlulaYAMLDocument(contentsOf: url, substitution: substitution)
    }

    public func rawValue(for key: String) -> String? {
        document.rawValue(for: key)
    }
}
