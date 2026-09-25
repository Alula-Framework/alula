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
/// Self-contained rather than sharing Alula Core's `RegistrationMacro`
/// (the shared expansion behind `@Component`/`@Service`/`@Repository`):
/// `AlulaWebMacrosImpl` does not depend on `AlulaCoreMacrosImpl`, the same
/// reason `@Controller` in this same file's sibling `ControllerMacro.swift`
/// duplicates rather than shares that logic. This mirrors `ComponentMacro`'s
/// property model, not `ControllerMacro`'s — no route metadata here.
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
        guard validateAttachmentTarget(declaration, in: context) else { return [] }

        let properties = try collectInjectedProperties(from: declaration, in: context)
        guard validateDistinctInjectedTypes(properties, in: context) else { return [] }
        guard validateNonInjectedStorage(declaration, injected: properties, in: context) else {
            return []
        }
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

    // MARK: - Injected-property model (mirrors ComponentMacro)

    private static func collectInjectedProperties(
        from declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [InjectedProperty] {
        var properties: [InjectedProperty] = []
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            guard let kind = injectionKind(of: variable, in: context) else { continue }
            guard let binding = variable.bindings.first,
                let pattern = binding.pattern.as(IdentifierPatternSyntax.self)
            else { continue }
            guard let typeAnnotation = binding.typeAnnotation else {
                context.diagnose(
                    .untypedInjection,
                    "@Inject/@ConfigValue properties need an explicit type annotation — injection resolves by static type.",
                    at: variable
                )
                continue
            }
            properties.append(
                InjectedProperty(
                    name: pattern.identifier.text,
                    typeText: typeAnnotation.type.trimmedDescription,
                    kind: kind,
                    node: variable
                )
            )
        }
        return properties
    }

    private static func injectionKind(
        of variable: VariableDeclSyntax,
        in context: some MacroExpansionContext
    ) -> InjectedProperty.Kind? {
        for attribute in variable.attributes {
            guard let attr = attribute.as(AttributeSyntax.self),
                let name = attr.attributeName.as(IdentifierTypeSyntax.self)?.name.text
            else { continue }
            switch name {
            case "Inject":
                return .inject
            case "ConfigValue":
                guard let key = firstArgumentSource(of: attr) else {
                    context.diagnose(
                        .configValueWithoutKey,
                        "@ConfigValue requires a key, e.g. @ConfigValue(\"server.port\").",
                        at: attr
                    )
                    return nil
                }
                return .configValue(
                    key: key, defaultValue: labeledArgumentSource(of: attr, label: "default"))
            default:
                continue
            }
        }
        return nil
    }

    private static func firstArgumentSource(of attribute: AttributeSyntax) -> String? {
        guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
            let first = arguments.first, first.label == nil
        else { return nil }
        let text = first.expression.trimmedDescription
        return text == "nil" ? nil : text
    }

    private static func labeledArgumentSource(of attribute: AttributeSyntax, label: String)
        -> String?
    {
        guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) else {
            return nil
        }
        for argument in arguments where argument.label?.text == label {
            return argument.expression.trimmedDescription
        }
        return nil
    }

    // MARK: - Validation (mirrors ComponentMacro)

    private static func validateAttachmentTarget(
        _ declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) -> Bool {
        if let classDecl = declaration.as(ClassDeclSyntax.self) {
            let isFinal = classDecl.modifiers.contains { $0.name.tokenKind == .keyword(.final) }
            if !isFinal {
                context.diagnose(
                    .unsupportedControllerDeclaration,
                    "@Middleware requires a final class (or a struct). Mark '\(classDecl.name.text)' final.",
                    at: classDecl.name,
                    fixIts: [.insertFinal(into: classDecl)]
                )
                return false
            }
            return true
        }
        if declaration.is(StructDeclSyntax.self) { return true }
        context.diagnose(
            .unsupportedControllerDeclaration,
            "@Middleware can only be attached to a final class or a struct.",
            at: declaration
        )
        return false
    }

    /// Two `@Inject` properties of the same type are a compile error. Mirrors
    /// `ComponentMacro`, including why: the qualified pair that used to be
    /// permitted here was never actually wired as two registrations, and the
    /// property-level qualifier that spelled it went in 0.20.0.
    private static func validateDistinctInjectedTypes(
        _ properties: [InjectedProperty],
        in context: some MacroExpansionContext
    ) -> Bool {
        // Keyed by type *and* named provider. `@Inject(from:)` is what makes
        // two properties of one type distinguishable, so two naming different
        // modules are fine; two naming the same one, or neither, are not.
        var seen: Set<String> = []
        var valid = true
        for property in properties {
            guard case .inject = property.kind else { continue }
            let key = "\(property.typeText)|\(property.providerText ?? "")"
            if !seen.insert(key).inserted {
                let sameProvider = property.providerText != nil
                context.diagnose(
                    .indistinguishableInjections,
                    sameProvider
                        ? "Two @Inject properties of type '\(property.typeText)' naming the same provider. Composition wires by type, so nothing distinguishes them."
                        : "Two @Inject properties of type '\(property.typeText)'. Composition wires by type, so nothing distinguishes them. Name the provider on one of them — @Inject(from: SomeModule.self) — or give them distinct types.",
                    at: property.node
                )
                valid = false
            }
        }
        return valid
    }

    private static func validateNonInjectedStorage(
        _ declaration: some DeclGroupSyntax,
        injected: [InjectedProperty],
        in context: some MacroExpansionContext
    ) -> Bool {
        let injectedNames = Set(injected.map(\.name))
        var valid = true
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            let isTypeLevel = variable.modifiers.contains {
                $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
            }
            if isTypeLevel { continue }
            let isVar = variable.bindingSpecifier.tokenKind == .keyword(.var)
            for binding in variable.bindings {
                guard binding.accessorBlock == nil,
                    binding.initializer == nil,
                    let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                    !injectedNames.contains(pattern.identifier.text),
                    !variable.carriesInjectionAttribute
                else { continue }
                if isVar, let type = binding.typeAnnotation?.type,
                    type.is(OptionalTypeSyntax.self)
                        || type.as(IdentifierTypeSyntax.self)?.name.text == "Optional"
                {
                    continue
                }
                context.diagnose(
                    .uninitializedStoredProperty,
                    "Stored property '\(pattern.identifier.text)' of a @Middleware type needs a default value — the generated initializer assigns only @Inject/@ConfigValue properties.",
                    at: variable
                )
                valid = false
            }
        }
        return valid
    }

    private static func registrationAccess(for declaration: some DeclGroupSyntax) -> String {
        let modifiers: DeclModifierListSyntax
        if let classDecl = declaration.as(ClassDeclSyntax.self) {
            modifiers = classDecl.modifiers
        } else if let structDecl = declaration.as(StructDeclSyntax.self) {
            modifiers = structDecl.modifiers
        } else {
            return ""
        }
        for modifier in modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.package):
                return "\(modifier.name.text) "
            default:
                continue
            }
        }
        return ""
    }
}
