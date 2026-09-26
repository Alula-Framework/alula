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
/// | `ALU-SCHED-9xxx` | Scheduled jobs |
///
/// A code's first digit is its family's, so a code read out of context
/// still says where it belongs.
public struct DiagnosticCode: Sendable, Hashable, CustomStringConvertible {
    public let id: String
    /// The page's title, e.g. "No module provides a required type".
    public let title: String
    public let severity: Diagnostic.Severity

    init(_ id: String, _ title: String, _ severity: Diagnostic.Severity = .error) {
        self.id = id
        self.title = title
        self.severity = severity
        self.externalDocumentationURL = nil
    }

    /// A code another package defines — alula-data's `ALD-…`, Hangar's
    /// `HGR-…` — so an error it throws renders through `Alula.run` with the
    /// code and a link to *its* page. Alula's own codes are listed in ``all``
    /// and have their pages here; these do not.
    public init(
        _ id: String, _ title: String, _ severity: Diagnostic.Severity = .error,
        documentationURL: String
    ) {
        self.id = id
        self.title = title
        self.severity = severity
        self.externalDocumentationURL = documentationURL
    }

    private let externalDocumentationURL: String?

    /// Where the full explanation lives online. Until Alula has a site of
    /// its own, the page in the repository — the same text `alula explain`
    /// prints.
    public var documentationURL: String {
        externalDocumentationURL ?? Self.documentationBase + id + ".md"
    }

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
    public static let indistinguishableInjections = DiagnosticCode(
        "ALU-DI-1015", "Two @Inject properties of one type")
    public static let untypedInjection = DiagnosticCode(
        "ALU-DI-1016", "An @Inject or @ConfigValue property has no written type")
    public static let uninitializedStoredProperty = DiagnosticCode(
        "ALU-DI-1017", "A stored property the generated initializer does not assign")
    public static let unsupportedComponentDeclaration = DiagnosticCode(
        "ALU-DI-1018", "@Component on something other than a struct or final class")
    public static let invalidInjectionTarget = DiagnosticCode(
        "ALU-DI-1019", "@Inject or @ConfigValue on something other than a stored instance property")

    // Controllers, routes, middleware, request binding.
    public static let duplicateRoute = DiagnosticCode("ALU-WEB-2001", "Two handlers for one method and path")
    public static let invalidHandlerParameter = DiagnosticCode(
        "ALU-WEB-2002", "A route handler parameter Alula cannot bind")
    public static let unsupportedControllerDeclaration = DiagnosticCode(
        "ALU-WEB-2003", "@Controller or @Middleware on something other than a struct or final class")
    public static let invalidRoutePath = DiagnosticCode("ALU-WEB-2004", "A malformed route path")
    public static let nonLiteralRoutePath = DiagnosticCode(
        "ALU-WEB-2005", "A route path that is not a string literal")
    public static let invalidHandlerDeclaration = DiagnosticCode(
        "ALU-WEB-2006", "A route handler declared in a way Alula cannot call")
    public static let routeOutsideController = DiagnosticCode(
        "ALU-WEB-2007", "A route attribute outside a @Controller")
    public static let pipelineNarrowing = DiagnosticCode(
        "ALU-WEB-2008", "A route's pipelines drop its controller's authentication", .warning)
    public static let undeclaredLane = DiagnosticCode(
        "ALU-WEB-2009", "A route runs through a lane nothing declares", .warning)
    public static let listenFailed = DiagnosticCode(
        "ALU-WEB-2010", "The server could not listen on its address")

    // OpenAPI generation.
    public static let undocumentedType = DiagnosticCode(
        "ALU-OAPI-3001", "A type the API uses has no schema", .warning)
    public static let undocumentedResponse = DiagnosticCode(
        "ALU-OAPI-3002", "A route's response cannot be described", .warning)

    // Configuration.
    public static let configValueWithoutKey = DiagnosticCode(
        "ALU-CONFIG-5001", "@ConfigValue without a literal key")
    public static let invalidSettingsDeclaration = DiagnosticCode(
        "ALU-CONFIG-5002", "@Settings declared in a way Alula cannot bind")
    public static let invalidSettingsProperty = DiagnosticCode(
        "ALU-CONFIG-5003", "A @Settings property Alula cannot bind")
    public static let missingConfigKey = DiagnosticCode(
        "ALU-CONFIG-5004", "A configuration key the base file does not define")
    public static let invalidConfigPrefix = DiagnosticCode(
        "ALU-CONFIG-5005", "A configuration prefix that cannot name environment variables")
    public static let configKeysUnchecked = DiagnosticCode(
        "ALU-CONFIG-5006", "The build could not check configuration keys", .warning)
    public static let unreadableConfigFile = DiagnosticCode(
        "ALU-CONFIG-5007", "The base configuration file does not parse")
    public static let invalidConfigValue = DiagnosticCode(
        "ALU-CONFIG-5008", "A configuration value of the wrong type")
    public static let configSourceFailed = DiagnosticCode(
        "ALU-CONFIG-5009", "A configuration source could not answer")
    public static let missingBaseConfigFile = DiagnosticCode(
        "ALU-CONFIG-5010", "No base configuration file at startup")
    public static let unsetConfigVariable = DiagnosticCode(
        "ALU-CONFIG-5011", "Configuration refers to an unset environment variable")
    public static let preRenameConfiguration = DiagnosticCode(
        "ALU-CONFIG-5012", "Configuration written for Flight, before the rename")
    public static let invalidModuleSettings = DiagnosticCode(
        "ALU-CONFIG-5013", "A module's settings are invalid")

    // Security and authentication composition.
    public static let rolesWithoutAuthentication = DiagnosticCode(
        "ALU-SEC-6001", "A route requires roles but authenticates no one")
    public static let competingTokenValidators = DiagnosticCode(
        "ALU-SEC-6002", "Several modules provide the bearer-token validator")

    // Commands.
    public static let duplicateCommand = DiagnosticCode("ALU-CMD-7001", "Two modules declare one command name")
    public static let unknownCommand = DiagnosticCode("ALU-CMD-7002", "No command by that name")

    // Lifecycle and module composition.
    public static let moduleCycle = DiagnosticCode("ALU-LIFE-8001", "Modules need each other in a cycle")
    public static let unconstructibleModule = DiagnosticCode(
        "ALU-LIFE-8002", "No initializer of a module can be satisfied")
    public static let uncollectedContribution = DiagnosticCode(
        "ALU-LIFE-8003", "A module contributes something nothing collects")
    public static let shutdownTimedOut = DiagnosticCode(
        "ALU-LIFE-8004", "Shutdown did not finish within its timeout")
    public static let moduleFailedWhileRunning = DiagnosticCode(
        "ALU-LIFE-8005", "A module failed after the application started")
    public static let serviceEndedOnItsOwn = DiagnosticCode(
        "ALU-LIFE-8006", "A module's service returned while the application ran")

    // Scheduled jobs.
    public static let invalidSchedule = DiagnosticCode(
        "ALU-SCHED-9001", "A cron expression or time zone that does not parse")
    public static let missingOrConflictingSchedule = DiagnosticCode(
        "ALU-SCHED-9002", "@Scheduled with no schedule, or with two")
    public static let nonLiteralScheduleArgument = DiagnosticCode(
        "ALU-SCHED-9003", "A @Scheduled argument that is not a literal")
    public static let invalidScheduledMethod = DiagnosticCode(
        "ALU-SCHED-9004", "@Scheduled on a method Alula cannot run as a job")
    public static let invalidScheduler = DiagnosticCode(
        "ALU-SCHED-9005", "@Scheduler on something that schedules nothing")

    /// Every code Alula defines, in order.
    public static let all: [DiagnosticCode] = [
        .missingProvider, .ambiguousProvider, .componentCycle, .namedProviderLacksType,
        .namedProviderNotIncluded, .namedProviderAmbiguous, .optionalInjection,
        .unscannedInjection, .ambiguousExistential, .untypedProvidedProperty,
        .nonPublicCrossModuleComponent, .removedScopeArgument, .removedQualifierArgument,
        .indistinguishableInjections, .untypedInjection, .uninitializedStoredProperty,
        .unsupportedComponentDeclaration, .invalidInjectionTarget,
        .duplicateRoute, .invalidHandlerParameter, .unsupportedControllerDeclaration,
        .invalidRoutePath, .nonLiteralRoutePath, .invalidHandlerDeclaration,
        .routeOutsideController, .pipelineNarrowing, .undeclaredLane, .listenFailed,
        .undocumentedType, .undocumentedResponse,
        .configValueWithoutKey, .invalidSettingsDeclaration, .invalidSettingsProperty,
        .missingConfigKey, .invalidConfigPrefix, .configKeysUnchecked, .unreadableConfigFile,
        .invalidConfigValue, .configSourceFailed, .missingBaseConfigFile, .unsetConfigVariable,
        .preRenameConfiguration, .invalidModuleSettings,
        .rolesWithoutAuthentication, .competingTokenValidators,
        .duplicateCommand, .unknownCommand,
        .moduleCycle, .unconstructibleModule, .uncollectedContribution, .shutdownTimedOut,
        .moduleFailedWhileRunning, .serviceEndedOnItsOwn,
        .invalidSchedule, .missingOrConflictingSchedule, .nonLiteralScheduleArgument,
        .invalidScheduledMethod, .invalidScheduler,
    ]
}
