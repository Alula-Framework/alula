// Generated from Diagnostics/*.md — do not edit. Regenerate with:
//   ALULA_REGENERATE_DIAGNOSTICS=1 swift test --filter DiagnosticCatalogTests
enum DiagnosticCatalog {
    static let pages: [String: String] = [
        "ALU-DI-1001": ##"""
            # ALU-DI-1001: No module provides a required type

            **Severity:** error

            ## Meaning

            Something in the application needs a value of a type — a component's
            `@Inject`, a route handler's parameter, a module's initializer — and no
            module in the application provides one.

            ## Why Alula rejects it

            Alula builds the whole application at compile time. A module provides a
            value by holding it as a stored property with a written type; the build
            matches every need against those properties. If nothing matches, there is
            nothing to pass, and the application cannot be assembled.

            ## Common causes

            - The module that owns the value is not in `modules:` (or in the
              `dependencies` of a module that is).
            - The module holds the value in a property with no written type —
              `let state = LabState()` — which the build cannot see. The diagnostic
              names such a property when it finds one.
            - The value is a plain class or struct nobody constructs: it should be a
              `@Component`, or a module should create and hold it.

            ## Fixes

            1. Add the providing module to `modules:`.
            2. Write the property's type: `let state: LabState = LabState()`.
            3. Make the type a `@Component`, or have a module construct and hold it.

            ## Example

            ```swift
            struct LabModule: AlulaModule {
                let state = LabState()            // invisible to composition
            }

            struct LabModule: AlulaModule {
                let state: LabState = LabState()  // provided
            }
            ```

            ## Related

            ALU-DI-1002 (several providers), ALU-DI-1011 (property with no written type).

            """##,
        "ALU-DI-1002": ##"""
            # ALU-DI-1002: Several modules provide the same type

            **Severity:** error

            ## Meaning

            Two or more modules provide a value of the same type, and something asks
            for that type without saying which one it means.

            ## Why Alula rejects it

            Composition never guesses. Picking one provider silently — the first, the
            last — is how a service ends up talking to the wrong database. When an
            application acquires a second provider, the build is the one place that
            knows, so it stops and asks.

            ## Common causes

            - A second instance of a module, such as another `PostgresDataModule` for
              an analytics database.
            - Two authentication modules that both provide a token validator.

            ## Fixes

            1. Say which provider an unqualified `@Inject` means, in the module that
               lists them:
               `static var defaultProviders: [any AlulaModule.Type] { [PrimaryModule.self] }`
            2. Name the other one where you want it: `@Inject(from: AnalyticsModule.self)`.
            3. Remove the provider you did not mean to include.

            ## Example

            ```swift
            @Inject var pool: PostgresDataSource                          // ambiguous
            @Inject(from: AnalyticsDataModule.self) var pool: PostgresDataSource  // chosen
            ```

            ## Related

            ALU-DI-1001, ALU-DI-1005, ALU-DI-1007.

            """##,
        "ALU-DI-1003": ##"""
            # ALU-DI-1003: Components depend on each other in a cycle

            **Severity:** error

            ## Meaning

            Following `@Inject` properties from one component leads back to it:
            `UserService → AuditService → UserService`.

            ## Why Alula rejects it

            Components are constructed once, in dependency order. A cycle has no first
            member, so no order can construct them.

            ## Common causes

            - Two services that each call the other.
            - A shared responsibility — auditing, notification — injected into the
              very service it depends on.

            ## Fixes

            1. Extract the shared responsibility into a third component both depend on.
            2. Inject a narrower dependency: a closure, a protocol with only the method
               needed, or a value the module provides.
            3. Pass the value at call time instead of holding it.

            ## Example

            ```text
            UserService → AuditService → UserService
            ```

            Extract `AuditLog` from `UserService`, and inject `AuditLog` into both.

            ## Related

            ALU-LIFE-8001 (modules in a cycle).

            """##,
        "ALU-DI-1005": ##"""
            # ALU-DI-1005: @Inject(from:) names a module that does not provide the type

            **Severity:** error

            ## Meaning

            `@Inject(from: SomeModule.self)` asks for a value from a particular module,
            and that module holds no stored property of the requested type.

            ## Why Alula rejects it

            `from:` is a promise the build checks rather than trusts. A module
            provides a value only by holding it as a stored property with a written
            type.

            ## Common causes

            - The wrong module is named.
            - The module computes the value instead of storing it, or stores it with no
              written type.

            ## Fixes

            1. Name the module that holds the value.
            2. Give the module a stored property of that type.

            ## Related

            ALU-DI-1002, ALU-DI-1006, ALU-DI-1011.

            """##,
        "ALU-DI-1006": ##"""
            # ALU-DI-1006: @Inject(from:) names a module the application does not include

            **Severity:** error

            ## Meaning

            `@Inject(from: SomeModule.self)` names a module that is not part of this
            application.

            ## Why Alula rejects it

            A module takes part only when it is in `modules:`, or in the `dependencies`
            of a module that is. A value cannot come from a module that is never built.

            ## Fixes

            1. Add the module to `modules:`, or to the `dependencies` of a module that
               is already there.
            2. Name a module the application does include.

            ## Related

            ALU-DI-1005.

            """##,
        "ALU-DI-1007": ##"""
            # ALU-DI-1007: @Inject(from:) names a module that provides the type more than once

            **Severity:** error

            ## Meaning

            The module named by `@Inject(from:)` holds two or more stored properties of
            the requested type, so naming the module does not pick one.

            ## Fixes

            1. Give each value its own type (a small wrapper struct is enough).
            2. Keep one of the properties and compute the other where it is used.

            ## Related

            ALU-DI-1002.

            """##,
        "ALU-DI-1008": ##"""
            # ALU-DI-1008: @Inject of an optional type

            **Severity:** error

            ## Meaning

            A component declares `@Inject var x: T?`.

            ## Why Alula rejects it

            Injection resolves a provider for the type written. `T?` is
            `Optional<T>`, which nothing provides, so it would always be `nil` — a
            dependency that silently never arrives.

            ## Fixes

            1. Drop the `?` if the dependency is required.
            2. If absence is meaningful, have a module provide an optional value and
               pass it explicitly, or resolve it by hand.

            ## Related

            ALU-DI-1001.

            """##,
        "ALU-DI-1009": ##"""
            # ALU-DI-1009: @Inject of a type nothing in the scan provides

            **Severity:** warning

            ## Meaning

            An `@Inject` names a type that is neither a scanned `@Component` nor a value
            any included module provides.

            ## Why Alula warns

            It may be provided some other way the build cannot see — a value supplied
            by hand at composition. If it is not, the application fails at startup
            instead of at build time.

            ## Fixes

            1. Make the type a `@Component`, or have a module hold it.
            2. If it is supplied by hand on purpose, acknowledge it with a
               `// alula:hand-registered` comment on the property.

            ## Related

            ALU-DI-1001.

            """##,
        "ALU-DI-1010": ##"""
            # ALU-DI-1010: @Inject of a protocol several components conform to

            **Severity:** warning

            ## Meaning

            An `@Inject` asks for an existential (`any Mailer`), and more than one
            scanned component conforms, so no bridge from the protocol to a concrete
            component was generated.

            ## Fixes

            1. Inject the concrete type you mean.
            2. Provide the existential from a module (`let mailer: any Mailer`), which
               makes the choice explicit.
            3. If you supply it by hand, acknowledge it with `// alula:hand-registered`.

            ## Related

            ALU-DI-1002.

            """##,
        "ALU-DI-1011": ##"""
            # ALU-DI-1011: A module property has no written type

            **Severity:** warning

            ## Meaning

            A module holds a stored property whose type is only inferred —
            `let state = LabState()` — so composition cannot offer it to anything that
            needs a `LabState`.

            ## Why Alula warns

            The build reads your source, not the type checker's results; a property's
            type must be written for it to be matched against needs.

            ## Fixes

            Write the type: `let state: LabState = LabState()`.

            ## Related

            ALU-DI-1001 (which names such a property when it is the likely cause).

            """##,
        "ALU-DI-1012": ##"""
            # ALU-DI-1012: A component used from another module is not public

            **Severity:** error

            ## Meaning

            A `@Component` declared in one Swift module is part of a graph composed in
            another, but the type is not `public`, so the generated composition cannot
            name it.

            ## Fixes

            Declare the component (and its initializer dependencies) `public`, or move
            it into the module that composes it.

            """##,
        "ALU-DI-1013": ##"""
            # ALU-DI-1013: The removed `scope:` argument

            **Severity:** error

            ## Meaning

            A component declares `scope:` — `@Component(scope: .transient)` or similar.
            The argument was removed in 0.20.0.

            ## Why Alula rejects it

            Singleton is the only lifetime. Nothing needed the others, and removing them
            removed the captive-dependency class of bug with them — an application-lived
            component can no longer hold a request-lived value. Per-request state
            travels on `RequestContext` (the authenticated principal is the worked
            example), and a pooled connection is leased per operation by the repository
            that holds the pool.

            ## Fixes

            Delete the argument: `@Component`.

            """##,
        "ALU-DI-1014": ##"""
            # ALU-DI-1014: The removed type-level `qualifier:` argument

            **Severity:** error

            ## Meaning

            A component declares a type-level `qualifier:`, removed in 0.20.0.

            ## Why Alula rejects it

            It expanded to nothing: composition wires by type, not by name. The
            property-level `@Inject("name")` went in the same release, and two `@Inject`
            properties of one type are a build error, because nothing distinguishes them.

            ## Fixes

            Delete the argument. To choose between providers of one type, use
            `defaultProviders` and `@Inject(from:)` (ALU-DI-1002).

            """##,
        "ALU-LIFE-8001": ##"""
            # ALU-LIFE-8001: Modules need each other in a cycle

            **Severity:** error

            ## Meaning

            Each module in a set needs, to be constructed, a value another in the set
            holds: `RelayModule` needs the component graph, and the graph needs a value
            `RelayModule` provides.

            ## Why Alula rejects it

            Modules are constructed in dependency order. A cycle has no first member.

            ## Fixes

            Move the shared value into a module both can take it from — often a small
            module that only holds it.

            ## Related

            ALU-DI-1003 (components in a cycle).

            """##,
        "ALU-LIFE-8002": ##"""
            # ALU-LIFE-8002: No initializer of a module can be satisfied

            **Severity:** error

            ## Meaning

            The build found no initializer of a module whose every parameter something
            in the application can supply.

            ## Fixes

            1. Add the modules that provide the missing parameters.
            2. Give the parameter a default value, or make it optional if absence is
               meaningful.
            3. Add an initializer the application can satisfy.

            ## Related

            ALU-DI-1001.

            """##,
        "ALU-LIFE-8003": ##"""
            # ALU-LIFE-8003: A module contributes something nothing collects

            **Severity:** error

            ## Meaning

            A module exposes a contribution — `[ChannelRegistration]`, routes,
            scheduled jobs — and no module in the application takes a list of that type,
            so the contribution would be silently dropped.

            ## Fixes

            Add the module that collects it to `modules:` (the diagnostic names it).

            """##,
    ]
}
