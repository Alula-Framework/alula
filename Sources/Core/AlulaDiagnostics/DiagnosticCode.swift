/// A stable diagnostic identifier, such as `ALU-DI-1001`.
///
/// Codes are part of Alula's public developer experience: they appear in
/// build output, CI logs and search results, and each has a page — `alula
/// explain <code>` offline, or ``documentationURL`` online. A code is never
/// renumbered or reused; a rule Alula stops enforcing keeps its page, marked
/// retired.
///
/// Families:
///
/// | Prefix | Area |
/// |---|---|
/// | `ALU-DI-1xxx` | Dependency injection and graph construction |
/// | `ALU-WEB-2xxx` | Controllers, routes, middleware, request binding |
/// | `ALU-OAPI-3xxx` | OpenAPI generation |
/// | `HGR-QUERY-4xxx` | Hangar query semantics |
/// | `ALU-CONFIG-5xxx` | Configuration |
/// | `ALU-SEC-6xxx` | Security and authentication composition |
/// | `ALU-CMD-7xxx` | Commands |
/// | `ALU-LIFE-8xxx` | Lifecycle and module composition |
public struct DiagnosticCode: Sendable, Hashable, CustomStringConvertible {
    public let id: String
    /// The page's title, e.g. "No module provides a required type".
    public let title: String
    public let severity: Diagnostic.Severity

    init(_ id: String, _ title: String, _ severity: Diagnostic.Severity = .error) {
        self.id = id
        self.title = title
        self.severity = severity
    }

    /// Where the full explanation lives online. Until Alula has a site of
    /// its own, the page in the repository — the same text `alula explain`
    /// prints.
    public var documentationURL: String { Self.documentationBase + id + ".md" }

    public static let documentationBase = "https://github.com/Alula-Framework/alula/blob/main/Diagnostics/"

    public var description: String { id }

    /// The full page for this code: meaning, why Alula rejects it, common
    /// causes, fixes, examples.
    public var page: String? { DiagnosticCatalog.pages[id] }

    /// The code with this id, if Alula defines one.
    public static func named(_ id: String) -> DiagnosticCode? {
        all.first { $0.id.uppercased() == id.uppercased() }
    }
}

// MARK: - The codes

extension DiagnosticCode {
    // Dependency injection and graph construction.
    public static let missingProvider = DiagnosticCode("ALU-DI-1001", "No module provides a required type")
    public static let ambiguousProvider = DiagnosticCode("ALU-DI-1002", "Several modules provide the same type")
    public static let componentCycle = DiagnosticCode("ALU-DI-1003", "Components depend on each other in a cycle")
    public static let namedProviderLacksType = DiagnosticCode(
        "ALU-DI-1005", "@Inject(from:) names a module that does not provide the type")
    public static let namedProviderNotIncluded = DiagnosticCode(
        "ALU-DI-1006", "@Inject(from:) names a module the application does not include")
    public static let namedProviderAmbiguous = DiagnosticCode(
        "ALU-DI-1007", "@Inject(from:) names a module that provides the type more than once")
    public static let optionalInjection = DiagnosticCode("ALU-DI-1008", "@Inject of an optional type")
    public static let unscannedInjection = DiagnosticCode(
        "ALU-DI-1009", "@Inject of a type nothing in the scan provides", .warning)
    public static let ambiguousExistential = DiagnosticCode(
        "ALU-DI-1010", "@Inject of a protocol several components conform to", .warning)
    public static let untypedProvidedProperty = DiagnosticCode(
        "ALU-DI-1011", "A module property has no written type", .warning)
    public static let nonPublicCrossModuleComponent = DiagnosticCode(
        "ALU-DI-1012", "A component used from another module is not public")
    public static let removedScopeArgument = DiagnosticCode("ALU-DI-1013", "The removed `scope:` argument")
    public static let removedQualifierArgument = DiagnosticCode(
        "ALU-DI-1014", "The removed type-level `qualifier:` argument")

    // Lifecycle and module composition.
    public static let moduleCycle = DiagnosticCode("ALU-LIFE-8001", "Modules need each other in a cycle")
    public static let unconstructibleModule = DiagnosticCode(
        "ALU-LIFE-8002", "No initializer of a module can be satisfied")
    public static let uncollectedContribution = DiagnosticCode(
        "ALU-LIFE-8003", "A module contributes something nothing collects")

    /// Every code Alula defines, in order.
    public static let all: [DiagnosticCode] = [
        .missingProvider, .ambiguousProvider, .componentCycle, .namedProviderLacksType,
        .namedProviderNotIncluded, .namedProviderAmbiguous, .optionalInjection,
        .unscannedInjection, .ambiguousExistential, .untypedProvidedProperty,
        .nonPublicCrossModuleComponent, .removedScopeArgument, .removedQualifierArgument,
        .moduleCycle, .unconstructibleModule, .uncollectedContribution,
    ]
}
