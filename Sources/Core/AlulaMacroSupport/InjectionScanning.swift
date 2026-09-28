import AlulaDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

// The half of every registration macro that reads the declaration: which
// properties are injected, what the attribute arguments say, what access the
// generated members get, and the validation that has to pass before anything
// is generated. `@Component` (and its stereotypes), `@Controller`,
// `@Middleware` and `@Scheduler` all use these; before, each carried its own
// copy, and the copies had drifted — only `@Component` diagnosed a static
// `@Inject`, and only `@Scheduler` gave a `package` type internal members.

/// Every `@Inject` / `@ConfigValue` property the declaration carries, in
/// declaration order, diagnosing the ones that cannot be injected.
///
/// A property is read from its first binding, as the registration generator
/// reads it: the two must agree on the initializer's labels, or the
/// composition root the generator writes does not compile.
public func collectInjectedProperties(
    from declaration: some DeclGroupSyntax,
    in context: some MacroExpansionContext
) -> [InjectedProperty] {
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
            context.diagnose(
                .invalidInjectionTarget,
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

/// Which injection attribute the property carries, if any. A `@ConfigValue`
/// without a key is diagnosed and treated as carrying none.
public func injectionKind(
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

/// Source text of the first unlabeled argument (a string literal in the
/// supported grammar), or nil. Kept as source text — the generated code
/// re-embeds it verbatim, so escapes survive untouched.
public func firstArgumentSource(of attribute: AttributeSyntax) -> String? {
    guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
        let first = arguments.first, first.label == nil
    else { return nil }
    let text = first.expression.trimmedDescription
    return text == "nil" ? nil : text
}

/// Source text of a labeled argument (e.g. `default:` on @ConfigValue),
/// or nil. Same verbatim re-embedding rationale as above.
public func labeledArgumentSource(of attribute: AttributeSyntax, label: String) -> String? {
    guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) else {
        return nil
    }
    for argument in arguments where argument.label?.text == label {
        return argument.expression.trimmedDescription
    }
    return nil
}

/// The access modifier, with its trailing space, for the generated members.
///
/// They must be callable from the generated cross-module composition root,
/// so they mirror the type's own access level: `public` and `package` carry
/// over, and `open` — which a member that cannot be overridden cannot
/// spell — becomes `public`. Anything else is internal, spelled as nothing.
public func registrationAccess(for declaration: some DeclGroupSyntax) -> String {
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
        case .keyword(.open):
            return "public "
        default:
            continue
        }
    }
    return ""
}

// MARK: - Validation

/// Final class or struct only. A non-final class would need a `required`
/// initializer to make the generated `Self(...)` legal in a static context —
/// deliberately unsupported rather than silently generating subclass-hostile
/// code. Actors are deferred: actor-based components are an Alula-wide
/// design question, not a macro detail to improvise.
///
/// `displayName` is the attribute as the author wrote it (`@Service`), and
/// `code` the one its family reports under.
public func validateFinalClassOrStruct(
    _ declaration: some DeclGroupSyntax,
    displayName: String,
    code: DiagnosticCode,
    in context: some MacroExpansionContext
) -> Bool {
    if let classDecl = declaration.as(ClassDeclSyntax.self) {
        let isFinal = classDecl.modifiers.contains { $0.name.tokenKind == .keyword(.final) }
        if !isFinal {
            context.diagnose(
                code,
                "\(displayName) requires a final class (or a struct). Mark '\(classDecl.name.text)' final.",
                at: classDecl.name,
                fixIts: [.insertFinal(into: classDecl)]
            )
            return false
        }
        return true
    }
    if declaration.is(StructDeclSyntax.self) { return true }
    context.diagnose(
        code,
        "\(displayName) can only be attached to a final class or a struct.",
        at: declaration
    )
    return false
}

/// Two `@Inject` properties of the same type are a compile error.
public func validateDistinctInjectedTypes(
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
    //
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

/// The generated initializer assigns only injected properties, so any other
/// stored property must carry a default value (or be an implicitly-nil
/// optional `var`). Without this check the failure is a "return from
/// initializer without initializing all stored properties" error pointing
/// *inside the macro expansion* — this diagnostic names the actual fix at the
/// actual property instead.
public func validateNonInjectedStorage(
    _ declaration: some DeclGroupSyntax,
    injected: [InjectedProperty],
    displayName: String,
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
            // An optional `var` is implicitly nil-initialized.
            if isVar, let type = binding.typeAnnotation?.type,
                type.is(OptionalTypeSyntax.self)
                    || type.as(IdentifierTypeSyntax.self)?.name.text == "Optional"
            {
                continue
            }
            context.diagnose(
                .uninitializedStoredProperty,
                "Stored property '\(pattern.identifier.text)' of a \(displayName) type needs a default value — the generated initializer assigns only @Inject/@ConfigValue properties.",
                at: variable
            )
            valid = false
        }
    }
    return valid
}
