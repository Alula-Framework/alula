import AlulaDiagnostics
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import AlulaMacroSupport
import SwiftSyntaxMacros

/// The shared expansion behind `@Service` and `@Repository`: a
/// parameterized initializer taking every `@Inject` property as a parameter
/// and reading every `@ConfigValue` property from `Configuration`. The
/// composition root calls it, wiring the injected values by type. The
/// container-era `init(_alula:)`, `_alulaRegister` thunk, and
/// `_AlulaRegistrable` conformance are gone with the container.
///
/// The two expand *identically*; the stereotype only tags the build-scanned
/// descriptor (for Actuator), not the expansion.
///
/// The authoritative expansions are the fixtures in AlulaCoreMacroTests
///.
public protocol RegistrationMacro: MemberMacro, ExtensionMacro {
    /// Source text of the `stereotype:` argument in the generated register
    /// call, or nil to omit it (the parameter defaults to `.component`).
    static var stereotypeArgument: String? { get }
    /// The attribute's user-facing spelling, for diagnostics.
    static var displayName: String { get }
}

/// `@Component` — removed; kept one release only because its declaration
/// is. The declaration is `@available(*, unavailable, renamed: "Service")`,
/// so any use is a compile error with a rename fix-it. The compiler still
/// expands the attribute after reporting that; without this type it would
/// add a second, misleading "external macro implementation type could not
/// be found" error. Delete it together with the declaration.
public struct ComponentMacro: RegistrationMacro {
    public static let stereotypeArgument: String? = nil
    public static let displayName = "@Component"
}

/// `@Service` — the general "put this in the graph" annotation.
public struct ServiceMacro: RegistrationMacro {
    public static let stereotypeArgument: String? = ".service"
    public static let displayName = "@Service"
}

/// `@Repository` — data access.
public struct RepositoryMacro: RegistrationMacro {
    public static let stereotypeArgument: String? = ".repository"
    public static let displayName = "@Repository"
}

extension RegistrationMacro {

    // MARK: - MemberMacro

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard
            validateFinalClassOrStruct(
                declaration, displayName: displayName, code: .unsupportedComponentDeclaration,
                in: context)
        else { return [] }

        let properties = collectInjectedProperties(from: declaration, in: context)
        guard validateDistinctInjectedTypes(properties, in: context) else { return [] }
        guard
            validateNonInjectedStorage(
                declaration, injected: properties, displayName: displayName, in: context)
        else { return [] }

        let access = registrationAccess(for: declaration)

        // Constructor injection: a component is built by the composition
        // root through this initializer. The container-era init(_alula:) and
        // _alulaRegister thunk are gone with the container.
        let parameterInit = parameterizedInitializer(
            properties: properties, access: access, declaration: declaration)
        _ = stereotypeArgument  // scanned from the attribute name, not emitted here
        return [parameterInit].compactMap { $0 }
    }

    // MARK: - ExtensionMacro

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // No conformance to emit: the container marker protocol is gone.
        []
    }

    // `parseComponentArguments` went with the `scope:`/`qualifier:` arguments
    // in 0.20.0. `@Service` and `@Repository` take no arguments
    // at all now, so there is nothing on the attribute to parse — a stale
    // `scope:` is rejected by the macro declaration itself, and the generator
    // turns that into a message naming the migration (`main.swift`'s
    // `diagnoseRemovedComponentArguments`) before the type checker's "extra
    // argument in call" can be the only thing the author sees.
}
