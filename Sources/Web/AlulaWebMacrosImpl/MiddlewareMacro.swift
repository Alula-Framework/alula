import AlulaDiagnostics
import SwiftDiagnostics
import AlulaMacroSupport
import SwiftSyntax
import SwiftSyntaxMacros

/// `@Middleware`. Expands like Alula Core's `@Component` — a parameterized
/// initializer taking the type's `@Inject`/`@ConfigValue` dependencies, built
/// once by the composition root — with one addition: the generated extension
/// also declares conformance to `AlulaWeb.Middleware`, so the type's own
/// `handle(_:next:)` is all it needs to write.
///
/// Not built on Alula Core's `RegistrationMacro` (the shared expansion behind
/// `@Component`/`@Service`/`@Repository`), because `AlulaWebMacrosImpl` does
/// not depend on `AlulaCoreMacrosImpl`; the injection half both use lives in
/// AlulaMacroSupport instead, as `@Controller`'s does.
///
/// The exact expansion is pinned by Tests/Web/AlulaWebMacroTests.
public struct MiddlewareMacro: MemberMacro, ExtensionMacro {

    // MARK: - MemberMacro

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard
            validateFinalClassOrStruct(
                declaration, displayName: "@Middleware", code: .unsupportedControllerDeclaration,
                in: context)
        else { return [] }

        let properties = collectInjectedProperties(from: declaration, in: context)
        guard validateDistinctInjectedTypes(properties, in: context) else { return [] }
        guard
            validateNonInjectedStorage(
                declaration, injected: properties, displayName: "@Middleware", in: context)
        else { return [] }
        let access = registrationAccess(for: declaration)

        // Constructor injection only: the parameterized initializer is the
        // whole of what a module (or a test) needs to build one. The
        // container-era `init(_alula:)` and `_alulaRegister` thunk are gone
        // with the container.
        let parameterInit = parameterizedInitializer(
            properties: properties, access: access, declaration: declaration)
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
        var extensions: [DeclSyntax] = []
        for requested in protocols {
            let name = requested.trimmedDescription
            switch true {
            case name.hasSuffix("Middleware"):
                extensions.append(
                    """
                    extension \(type.trimmed): AlulaWeb.Middleware {}
                    """)
            default:
                continue
            }
        }
        return extensions.compactMap { $0.as(ExtensionDeclSyntax.self) }
    }
}
