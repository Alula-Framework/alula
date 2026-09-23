import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import AlulaMacroSupport
import SwiftSyntaxMacros

/// The shared expansion behind `@Component` and its stereotypes: a
/// parameterized initializer taking every `@Inject` property as a parameter
/// and reading every `@ConfigValue` property from `Configuration`. The
/// composition root calls it, wiring the injected values by type. The
/// container-era `init(_alula:)`, `_alulaRegister` thunk, and
/// `_AlulaRegistrable` conformance are gone with the container.
///
/// Stereotypes expand *identically* to `@Component`; the stereotype only
/// tags the build-scanned descriptor (for Actuator), not the expansion.
///
/// The authoritative expansions are the fixtures in AlulaCoreMacroTests
///.
public protocol RegistrationMacro: MemberMacro, ExtensionMacro {
    /// Source text of the `stereotype:` argument in the generated register
    /// call, or nil to omit it (`@Component` — the parameter defaults to
    /// `.component`, keeping the base expansion unchanged).
    static var stereotypeArgument: String? { get }
    /// The attribute's user-facing spelling, for diagnostics.
    static var displayName: String { get }
}

/// `@Component` — the base registration macro; no stereotype tag.
public struct ComponentMacro: RegistrationMacro {
    public static let stereotypeArgument: String? = nil
    public static let displayName = "@Component"
}

/// `@Service` — business logic, third-party clients.
public struct ServiceMacro: RegistrationMacro {
    public static let stereotypeArgument: String? = ".service"
    public static let displayName = "@Service"
}

/// `@Repository` — data access.
public struct RepositoryMacro: RegistrationMacro {
    public static let stereotypeArgument: String? = ".repository"
    public static let displayName = "@Repository"
}

// MARK: - Injected-property model
// (File scope — nested types are not permitted in protocol extensions.)

extension RegistrationMacro {

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

    // MARK: - Validation

    /// Final class or struct only. Non-final classes would need a `required`
    /// initializer to make the generated `Self(...)` legal in a static
    /// context — deliberately unsupported in v1 rather than silently
    /// generating subclass-hostile code. Actors are deferred: actor-based
    /// components are an Alula-wide design question, not
    /// a macro detail to improvise.
    private static func validateAttachmentTarget(
        _ declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) -> Bool {
        if let classDecl = declaration.as(ClassDeclSyntax.self) {
            let isFinal = classDecl.modifiers.contains { $0.name.tokenKind == .keyword(.final) }
            if !isFinal {
                context.diagnoseError(
                    "component.nonfinal",
                    "\(displayName) requires a final class (or a struct). Mark '\(classDecl.name.text)' final.",
                    at: classDecl.name
                )
                return false
            }
            return true
        }
        if declaration.is(StructDeclSyntax.self) { return true }
        context.diagnoseError(
            "component.unsupported",
            "\(displayName) can only be attached to a final class or a struct.",
            at: declaration
        )
        return false
    }

    /// Two `@Inject` properties of the same type are a compile error.
    private static func validateDistinctInjectedTypes(
        _ properties: [InjectedProperty],
        in context: some MacroExpansionContext
    ) -> Bool {
        // Composition wires by type, so two properties of one type are two
        // requests for the same instance. There is nothing in the program that
        // could distinguish them.
        //
        // This shape was once permitted. `@Inject("analytics")` beside a bare
        // `@Inject` read as two different registrations — matching alula-data's
        // convention of registering the primary datasource unqualified *as well
        // as* by name — and the check let that pair through. It was never true:
        // the wiring ignored the qualifier and handed both properties the same
        // instance, silently. 0.20.0 removed the property-level qualifier, and
        // with it the only spelling of the distinction.
        //
        // Recorded as history rather than rationale: the pair is not merely
        // refused here, it is no longer expressible, and it cannot be
        // "restored" until naming on the providing side gives it something to
        // mean.
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
                context.diagnoseError(
                    "inject.ambiguous",
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

    /// M-3 : the generated initializer assigns only
    /// injected properties, so any other stored property must carry a default
    /// value (or be an implicitly-nil optional `var`). Without this check the
    /// failure is a "return from initializer without initializing all stored
    /// properties" error pointing *inside the macro expansion* — this
    /// diagnostic names the actual fix at the actual property instead.
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
                    !injectedNames.contains(pattern.identifier.text)
                else { continue }
                // An optional `var` is implicitly nil-initialized.
                if isVar, let type = binding.typeAnnotation?.type,
                    type.is(OptionalTypeSyntax.self)
                        || type.as(IdentifierTypeSyntax.self)?.name.text == "Optional"
                {
                    continue
                }
                context.diagnoseError(
                    "component.uninitialized",
                    "Stored property '\(pattern.identifier.text)' of a \(displayName) type needs a default value — the generated initializer assigns only @Inject/@ConfigValue properties.",
                    at: variable
                )
                valid = false
            }
        }
        return valid
    }

    // MARK: - Collection

    private static func collectInjectedProperties(
        from declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [InjectedProperty] {
        var properties: [InjectedProperty] = []
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            guard let kind = injectionKind(of: variable, in: context) else { continue }
            // A type-level property was collected like any other, and the
            // generated initializer then assigned to a static member —
            // a compile error inside an expansion the author cannot see,
            // instead of a diagnostic naming the problem.
            if variable.modifiers.contains(where: {
                $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
            }) {
                context.diagnoseError(
                    "injected.static",
                    """
                    Injection is per-instance: the generated initializer assigns the \
                    properties, and a static property has no instance to belong to. Make \
                    it an instance property, or set it explicitly where it is used.
                    """,
                    at: variable
                )
                continue
            }
            guard let binding = variable.bindings.first,
                let pattern = binding.pattern.as(IdentifierPatternSyntax.self)
            else { continue }
            guard let typeAnnotation = binding.typeAnnotation else {
                context.diagnoseError(
                    "injected.untyped",
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
                    context.diagnoseError(
                        "configvalue.nokey",
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

    /// Source text of the first unlabeled argument (a string literal in the
    /// supported grammar), or nil. Kept as source text — the generated code
    /// re-embeds it verbatim, so escapes survive untouched.
    private static func firstArgumentSource(of attribute: AttributeSyntax) -> String? {
        guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
            let first = arguments.first, first.label == nil
        else { return nil }
        let text = first.expression.trimmedDescription
        return text == "nil" ? nil : text
    }

    /// Source text of a labeled argument (e.g. `default:` on @ConfigValue),
    /// or nil. Same verbatim re-embedding rationale as above.
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

    // `parseComponentArguments` went with the `scope:`/`qualifier:` arguments
    // in 0.20.0. `@Component`, `@Service` and `@Repository` take no arguments
    // at all now, so there is nothing on the attribute to parse — a stale
    // `scope:` is rejected by the macro declaration itself, and the generator
    // turns that into a message naming the migration (`main.swift`'s
    // `diagnoseRemovedComponentArguments`) before the type checker's "extra
    // argument in call" can be the only thing the author sees.

    /// The generated initializer must be callable from the generated
    /// cross-module composition root — so it mirrors the type's own access
    /// level.
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
