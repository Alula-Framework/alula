import AlulaMacroSupport
import AlulaRouteScan
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Controller` (§4). Expands like Alula Core's `@Component` — a
/// parameterized initializer over its `@Inject`/`@ConfigValue` properties —
/// with one purely additive difference: it also emits one route *factory* per
/// mapped method, each carrying (HTTP method, path pattern, encoded handler
/// thunk) and building the controller to run that method as a
/// `RouteRegistration` value. Routing is not a distinct system from dependency
/// injection.
///
/// `@Controller`'s own optional path argument is a base path, combined with
/// every mapped method's path (Spring's class+method `@RequestMapping`
/// combination rule — see `RouteScanning.combinePaths`); the combination is
/// resolved to a single literal at macro-expansion time, so it costs nothing
/// at runtime and duplicate-route detection runs on the already-combined
/// paths.
///
/// The injection half (`@Inject`/`@ConfigValue` handling, attachment and
/// storage validation) deliberately mirrors ComponentMacro line for line —
/// same diagnostics, same generated shapes — so a controller author's mental
/// model transfers from components unchanged. The authoritative expansions
/// are the fixtures in AlulaWebMacroTests.
public struct ControllerMacro: MemberMacro, ExtensionMacro {

    // MARK: - Injected-property model (mirrors ComponentMacro)

    // MARK: - MemberMacro

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard validateAttachmentTarget(declaration, in: context) != nil else { return [] }

        let properties = collectInjectedProperties(from: declaration, in: context)
        guard validateDistinctInjectedTypes(properties, in: context) else { return [] }
        guard validateNonInjectedStorage(declaration, injected: properties, in: context) else {
            return []
        }

        let basePath = RouteScanning.basePath(
            of: node, diagnostics: MacroRouteDiagnostics(context: context))
        let routes = collectRoutes(from: declaration, basePath: basePath, in: context)
        let combinedRoutes = routes.map { route in
            (route: route, path: RouteScanning.combinePaths(basePath, route.path))
        }
        guard validateNoDuplicateRoutes(combinedRoutes, in: context) else { return [] }

        let access = registrationAccess(for: declaration)

        // A route's own `pipelines:` replaces the controller's rather than
        // adding to it — the only rule that can express both "public
        // controller, one authenticated route" and "authenticated
        // controller, one public route". Saying nothing inherits.
        let controllerPipelines = RouteScanning.pipelines(of: node)
        // Roles *add* rather than replace: a controller's apply to every
        // route below it, and a route's narrow further. The opposite rule
        // would let a route widen access by naming a role its controller does
        // not require, which is the one direction a route should not move on
        // its own.
        let controllerRoles = RouteScanning.roles(of: node)
        // The per-route factories are the whole of what a controller emits for
        // wiring now: each builds the controller and runs one method. The
        // composition root's `alulaRoutes(graph)` calls them. The container
        // era's init(_alula:) and _alulaRegister thunks are gone.
        var factories: [DeclSyntax] = []
        for (index, (route, path)) in combinedRoutes.enumerated() {
            let pipelines = RouteScanning.resolvedPipelines(
                route: route.pipelinesText, controller: controllerPipelines)
            if let routePipelines = route.pipelinesText {
                diagnoseSecurityNarrowing(
                    controller: controllerPipelines, route: routePipelines,
                    at: route.attribute, method: route.methodName, in: context)
            }
            // A role check on a lane that establishes no identity can only
            // ever reject, so it is a mistake rather than a policy.
            let isPublic = (pipelines ?? "").contains(".public")
            let declaredRoles = [controllerRoles, route.rolesText].compactMap { $0 }
            var route = route
            route.roleChecks = isPublic ? [] : declaredRoles
            if isPublic, !declaredRoles.isEmpty {
                context.diagnoseError(
                    "route.roles.public",
                    """
                    '\(route.methodName)' requires roles but runs on '.public', which \
                    establishes no principal — every request would be rejected. Give it a \
                    lane that authenticates, or drop the roles.
                    """,
                    at: route.attribute)
            }
            factories.append(
                DeclSyntax(
                    stringLiteral: routeFactory(
                        for: route, path: path, pipelines: pipelines, index: index)))
        }

        let parameterInit = parameterizedInitializer(
            properties: properties, access: access, declaration: declaration)
        let aggregate = routesAggregate(for: combinedRoutes, access: access)
        return [parameterInit].compactMap { $0 } + factories + [aggregate].compactMap { $0 }
    }

    /// Every route this controller declares, in one call.
    ///
    /// The per-route factories are named `_alulaRoute_<method>_<index>`, and
    /// that index is a *position*: a caller naming one is pinned to the order
    /// the routes happen to appear in, so inserting a route above it silently
    /// renumbers its neighbours. Worse, the index is derived twice — here, and
    /// again by the registration generator scanning the same source — and the
    /// two must agree or the build fails at link time with an undefined symbol.
    ///
    /// This is the same list without either hazard. A test that wants the whole
    /// controller hands over one `make` closure and gets every route back:
    ///
    /// ```swift
    /// TestClient(routes: UserController.alulaRoutes { _ in
    ///     UserController(users: MockUserService())
    /// })
    /// ```
    ///
    /// The individual factories remain, because registering a *subset*
    /// deliberately — one route of a controller, to isolate a middleware lane —
    /// is a real thing tests do, and this cannot express it.
    private static func routesAggregate(
        for combinedRoutes: [(route: ScannedRoute, path: String)], access: String
    ) -> DeclSyntax? {
        guard !combinedRoutes.isEmpty else { return nil }
        let calls =
            combinedRoutes
            .enumerated()
            .map { "Self.\(factoryName(for: $0.element.route, index: $0.offset))(make)" }
            .joined(separator: ",\n                ")
        return DeclSyntax(
            stringLiteral: """
                \(access)static func alulaRoutes(\
                _ make: @escaping @Sendable (AlulaWeb.RequestContext) throws -> Self\
                ) -> [AlulaWeb.RouteRegistration] {
                    [
                        \(calls)
                    ]
                }
                """)
    }

    /// The name of one route's factory. Unique per route rather than per
    /// method, because one method may carry several route attributes.
    private static func factoryName(for route: ScannedRoute, index: Int) -> String {
        "_alulaRoute_\(route.methodName)_\(index)"
    }

    /// One route, as a factory taking the controller it should call.
    ///
    /// The whole registration lives here — path, kind, lanes, body mode, body
    /// decoding, return encoding, upgrade shaping — parameterised by *how* the
    /// controller is obtained and by nothing else. That parameter is the seam
    /// COMPOSITION-MIGRATION.md §2.1a needs: `alulaRoutes` passes a closure
    /// that constructs the controller per request from a `AlulaGraph`, so a
    /// per-request controller stays per request and nothing else has to move —
    /// in particular the handler thunk stays in
    /// the macro, where the route scanner already lives, rather than being
    /// reimplemented in the generator and drifting from it.
    ///
    /// `make` takes the context so a constructor can use request values; one that
    /// needs none simply ignores it.
    private static func routeFactory(
        for route: ScannedRoute, path: String, pipelines: String?, index: Int
    ) -> String {
        let kind = route.kind.isUpgrade ? ".upgrade(.webSocket)" : ".http"

        // In the handler's own declaration order. Swift requires arguments
        // in that order, and emitting a fixed body-then-query-then-segments
        // order made `(_ context:, slug: String, body: Request)` fail with
        // `argument 'slug' must precede argument 'body'` from inside this
        // expansion — an ordering rule nothing documented.
        var call = "controller.\(route.methodName)(context"
        for label in route.argumentLabels {
            call += ", \(label): \(label)"
        }
        call += ")"
        if route.isAsync { call = "await \(call)" }
        if route.isThrows { call = "try \(call)" }

        var handlerLines: [String] = []
        // Authorisation before construction: an unauthorised request should
        // not reach application code, and a controller's initializer is
        // application code.
        for roles in route.roleChecks {
            handlerLines.append("try AlulaWeb.requireRoles(\(roles), in: context)")
        }
        handlerLines.append("let controller = try make(context)")
        if let bodyType = route.bodyTypeText {
            handlerLines.append(
                "let body = try AlulaWeb.decodeRequestBody(\(bodyType).self, from: context)")
        }
        if let queryType = route.queryTypeText {
            handlerLines.append(
                "let query = try AlulaWeb.decodeQuery(\(queryType).self, from: context)")
        }
        // Parsed before the controller is called, so a handler never receives
        // a segment it would have to check. A segment that will not parse is a
        // 400 from here, naming the parameter and the type.
        for parameter in route.pathParameters {
            handlerLines.append(
                """
                let \(parameter.name) = try AlulaWeb.decodePathParameter(\
                \(parameter.typeText).self, named: "\(parameter.name)", from: context)
                """)
        }
        if route.kind.isUpgrade {
            handlerLines.append("let upgradeHandler = \(call)")
            handlerLines.append(
                "return AlulaWeb.Response.upgrade(handler: upgradeHandler, context: context)")
        } else if route.returnTypeText != nil {
            handlerLines.append("let result = \(call)")
            handlerLines.append("return try AlulaWeb.encodeResponse(result, for: context)")
        } else {
            handlerLines.append("\(call)")
            handlerLines.append("return AlulaWeb.Response.noContent")
        }

        let pipelinesClause = pipelines.map { ", pipelines: \($0)" } ?? ""
        let bodyModeClause: String
        if route.isStreamingBody {
            bodyModeClause = ", bodyMode: .streaming(maxBytes: \(route.maxBodyBytesText ?? "nil"))"
        } else if let maxBytes = route.maxBodyBytesText {
            bodyModeClause = ", bodyMode: .buffered(maxBytes: \(maxBytes))"
        } else {
            bodyModeClause = ""
        }

        let timeoutClause = route.timeoutText.map { ", timeout: \($0)" } ?? ""

        var lines: [String] = []
        lines.append(
            "static func \(factoryName(for: route, index: index))(_ make: @escaping @Sendable (AlulaWeb.RequestContext) throws -> Self) -> AlulaWeb.RouteRegistration {"
        )
        lines.append(
            "    AlulaWeb.RouteRegistration(method: \"\(route.kind.httpMethod)\", path: \"\(path)\", kind: \(kind), source: String(reflecting: Self.self) + \".\(route.methodName)\"\(pipelinesClause)\(bodyModeClause)\(timeoutClause)) { context in"
        )
        for line in handlerLines {
            lines.append("        \(line)")
        }
        lines.append("    }")
        lines.append("}")
        return lines.joined(separator: "\n")
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

    // MARK: - Route collection

    private static func collectRoutes(
        from declaration: some DeclGroupSyntax,
        basePath: String,
        in context: some MacroExpansionContext
    ) -> [ScannedRoute] {
        var routes: [ScannedRoute] = []
        for member in declaration.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self) else { continue }
            routes.append(
                contentsOf: RouteScanning.scanRoutes(
                    of: function, basePath: basePath,
                    diagnostics: MacroRouteDiagnostics(context: context)))
        }
        return routes
    }

    /// Duplicates are checked on the *combined* path — two methods that only
    /// collide once a `@Controller` base path is applied are exactly as
    /// wrong as two that collide without one.
    private static func validateNoDuplicateRoutes(
        _ routes: [(route: ScannedRoute, path: String)],
        in context: some MacroExpansionContext
    ) -> Bool {
        var seen: [String: String] = [:]  // "METHOD path" → method name
        var valid = true
        for (route, path) in routes {
            let key = "\(route.kind.httpMethod) \(path)"
            if let existing = seen[key] {
                context.diagnoseError(
                    "route.duplicate",
                    "Route '\(key)' is declared by both '\(existing)' and '\(route.methodName)' in this controller.",
                    at: route.node
                )
                valid = false
            }
            seen[key] = route.methodName
        }
        return valid
    }

    /// The `pipelines:` argument's source text, re-embedded verbatim into
    /// every generated RouteRegistration — or nil for the default lane.
    /// Verbatim like @Component's `scope:`: the expression is evaluated in
    /// the expansion, so `[.defaultLane, "admin"]` and a constant both work.

    /// The canonical security lanes, in every spelling a declaration site can
    /// use. A macro sees source text and nothing else — it cannot resolve
    /// `.authenticated` to a value — so recognizing a security lane means
    /// recognizing how it is written. This is why the lanes are canonical
    /// names on `PipelineLane` rather than free-form strings: with arbitrary
    /// strings there is nothing here to match, and the warning below cannot
    /// exist.
    private static let securityLaneSpellings: Set<String> = [
        ".authentication", ".authenticated",
        "PipelineLane.authentication", "PipelineLane.authenticated",
        "\"authentication\"", "\"authenticated\"",
    ]

    private static let publicLaneSpellings: Set<String> = [
        ".public", "PipelineLane.public", "\"public\"",
    ]

    /// Warns when a route replaces its controller's lanes with a set that
    /// drops the controller's authentication, without saying `.public`.
    ///
    /// A warning rather than an error, deliberately: narrowing is legitimate,
    /// and the build should not fail on a judgment the author is entitled to
    /// make. But dropping authentication silently is the mistake worth
    /// catching, and naming `.public` *is* the acknowledgment — it records
    /// the intent in the declaration instead of a comment beside it, and
    /// makes "every deliberately-public route under an authenticated
    /// controller" greppable. This mirrors the warn-vs-error discipline
    /// already in `alula-registration-gen`.
    private static func diagnoseSecurityNarrowing(
        controller: String?, route: String, at attribute: AttributeSyntax,
        method: String, in context: some MacroExpansionContext
    ) {
        guard let controller else { return }
        let controllerLanes = laneSpellings(in: controller)
        let routeLanes = laneSpellings(in: route)

        let dropped =
            controllerLanes
            .filter(securityLaneSpellings.contains)
            .filter { !routeLanes.contains($0) }
        guard !dropped.isEmpty else { return }
        // `.public` is the acknowledgment; having said it, the author is done.
        guard routeLanes.isDisjoint(with: publicLaneSpellings) else { return }
        // Still running some other security lane is a swap, not a drop.
        guard routeLanes.isDisjoint(with: securityLaneSpellings) else { return }

        context.diagnoseWarning(
            "route.pipelines.narrowing",
            """
            '\(method)' replaces its controller's pipelines and drops \
            \(dropped.sorted().joined(separator: ", ")), so this route runs without \
            authentication. A route's 'pipelines:' replaces the controller's rather than \
            adding to it. If that is intended, say 'pipelines: [.public]' — that is how a \
            deliberately public route records the decision.
            """,
            at: attribute
        )
    }

    /// The lane spellings in a `pipelines:` argument's source text, split on
    /// the array literal's commas. Text-level by necessity, and only ever
    /// used to compare against the canonical spellings above.
    private static func laneSpellings(in text: String) -> Set<String> {
        func trimmed(_ s: Substring) -> String {
            var slice = s
            while let first = slice.first, first.isWhitespace || first == "[" {
                slice = slice.dropFirst()
            }
            while let last = slice.last, last.isWhitespace || last == "]" {
                slice = slice.dropLast()
            }
            return String(slice)
        }
        return Set(
            text.split(separator: ",")
                .map(trimmed)
                .filter { !$0.isEmpty })
    }

    /// `@Controller`'s own base-path argument (Spring-style combination — see
    /// the macro declaration's doc comment). Returns `""` for "no base path":
    /// omitted, explicit `nil`, empty string, and bare `"/"` are all the
    /// identity element for `RouteScanning.combinePaths`.

    // MARK: - Validation (mirrors ComponentMacro)

    /// Final class or struct only, same rule and reasoning as `@Component`.
    /// Returns the declared type name for use in route sources.
    private static func validateAttachmentTarget(
        _ declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) -> String? {
        if let classDecl = declaration.as(ClassDeclSyntax.self) {
            let isFinal = classDecl.modifiers.contains { $0.name.tokenKind == .keyword(.final) }
            if !isFinal {
                context.diagnoseError(
                    "controller.nonfinal",
                    "@Controller requires a final class (or a struct). Mark '\(classDecl.name.text)' final.",
                    at: classDecl.name
                )
                return nil
            }
            return classDecl.name.text
        }
        if let structDecl = declaration.as(StructDeclSyntax.self) {
            return structDecl.name.text
        }
        context.diagnoseError(
            "controller.unsupported",
            "@Controller can only be attached to a final class or a struct.",
            at: declaration
        )
        return nil
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
                if isVar, let type = binding.typeAnnotation?.type,
                    type.is(OptionalTypeSyntax.self)
                        || type.as(IdentifierTypeSyntax.self)?.name.text == "Optional"
                {
                    continue
                }
                context.diagnoseError(
                    "controller.uninitialized",
                    "Stored property '\(pattern.identifier.text)' of a @Controller type needs a default value — the generated initializer assigns only @Inject/@ConfigValue properties.",
                    at: variable
                )
                valid = false
            }
        }
        return valid
    }

    // MARK: - Collection (mirrors ComponentMacro)

    private static func collectInjectedProperties(
        from declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) -> [InjectedProperty] {
        var properties: [InjectedProperty] = []
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            guard let kind = injectionKind(of: variable, in: context) else { continue }
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

    /// The generated initializer and route factories mirror the type's own
    /// access level so the generated cross-module composition root can build
    /// and register it (Alula Core P-1).
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
