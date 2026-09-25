// Generated from Diagnostics/*.md — do not edit. Regenerate with:
//   ALULA_REGENERATE_DIAGNOSTICS=1 swift test --filter DiagnosticCatalogTests
enum DiagnosticCatalog {
    static let pages: [String: String] = [
        "ALU-CMD-7001": ##"""
            # ALU-CMD-7001: Two modules declare one command name

            **Severity:** error

            ## Meaning

            Two modules both declare a `CommandRegistration` with the same name.

            ## Why Alula rejects it

            Command names are one namespace across the application. Running whichever
            module was listed first would let the order of `modules:` decide what
            `swift run App <name>` does.

            ## Common causes

            - Two modules that each ship a `migrate` or `seed` command.

            ## Fixes

            1. Rename one of them — a module prefix works: `billing-seed`.

            ## Example

            ```swift
            CommandRegistration("billing-seed", abstract: "Seed billing plans") { context in … }
            ```

            ## Related

            ALU-CMD-7002.

            """##,
        "ALU-CMD-7002": ##"""
            # ALU-CMD-7002: No command by that name

            **Severity:** error

            ## Meaning

            The application was started with an argument that names no command, such as
            `swift run App sync-inventroy`. The report lists the commands there are.

            ## Why Alula rejects it

            Any first argument that is not a flag is read as a command name, so a typo
            cannot quietly start the server instead.

            ## Common causes

            - A typo in the name.
            - The module that declares the command is not in `modules:`.

            ## Fixes

            1. Use a name from the listing — `swift run App commands` prints it.
            2. Add the module that declares the command to `modules:`.
            3. To serve, pass no argument, or `serve`.

            ## Related

            ALU-CMD-7001.

            """##,
        "ALU-CONFIG-5001": ##"""
            # ALU-CONFIG-5001: @ConfigValue without a literal key

            **Severity:** error

            ## Meaning

            A `@ConfigValue` has no key, or its key is not a string literal.

            ## Why Alula rejects it

            The key is what the value is read from, and the build checks keys against
            your configuration files. A missing or computed key cannot be checked.

            ## Fixes

            1. Give the key as a string literal: `@ConfigValue("server.port")`.
            2. For many related values, use a `@Settings` type with a namespace.

            ## Example

            ```swift
            @ConfigValue("mail.from") var from: String
            ```

            ## Related

            ALU-CONFIG-5002.

            """##,
        "ALU-CONFIG-5002": ##"""
            # ALU-CONFIG-5002: @Settings declared in a way Alula cannot bind

            **Severity:** error

            ## Meaning

            A `@Settings` type has no literal namespace, or is not a struct or a final
            class.

            ## Why Alula rejects it

            `@Settings("auth")` binds every property under the `auth.` prefix. The
            namespace has to be known at build time to check the keys, and the macro
            needs a struct or final class to generate the initializer that binds them.

            ## Fixes

            1. Give a namespace literal: `@Settings("auth")`.
            2. Mark the class `final` (the build offers this as a fix-it), or make it a struct.

            ## Example

            ```swift
            @Settings("auth")
            struct AuthSettings {
                var sessionLifetime: Int = 3600
            }
            ```

            ## Related

            ALU-CONFIG-5001, ALU-CONFIG-5003.

            """##,
        "ALU-CONFIG-5003": ##"""
            # ALU-CONFIG-5003: A @Settings property Alula cannot bind

            **Severity:** error

            ## Meaning

            A property of a `@Settings` type (or a `@Secret`) is declared in a way
            binding cannot handle:

            - `@Inject` inside settings;
            - no written type;
            - an optional type;
            - a `let` with a default value;
            - `@Secret` on something that is not a stored property.

            ## Why Alula rejects it

            Settings bind configuration once, at bootstrap, by static type. A
            dependency does not belong there; an untyped property has nothing to bind
            to; an optional would leave "what did we configure" with no single answer;
            and a `let` default could never be overridden by configuration.

            ## Fixes

            1. Move dependencies to a `@Service` or `@Component`.
            2. Write the type.
            3. Replace the optional with a concrete default.
            4. Use `var` for a property with a default.

            ## Example

            ```swift
            @Settings("mail")
            struct MailSettings {
                var host: String = "localhost"
                @Secret var password: String
            }
            ```

            ## Related

            ALU-CONFIG-5002.

            """##,
        "ALU-CONFIG-5004": ##"""
            # ALU-CONFIG-5004: A configuration key the base file does not define

            **Severity:** error

            ## Meaning

            A `@ConfigValue` key, or a `@Settings` property's key, has no default and is
            not in the application's base configuration file (`alula.yaml`, or
            `<prefix>.yaml`).

            ## Why Alula rejects it

            A key with no value and no default fails the application at startup. The
            base file is the one layer every environment loads, so a key missing from it
            is missing everywhere unless something else happens to supply it — and the
            build can check that now rather than a deploy finding out.

            ## Common causes

            - A new `@ConfigValue` whose key was not added to `alula.yaml`.
            - A typo in the key, or in the YAML nesting.

            ## Fixes

            1. Add the key to the base file. For a value the environment supplies, a placeholder is enough: `password: ${MAIL_PASSWORD}`.
            2. Or give it a default: `@ConfigValue("mail.port", default: 25)`, or a default value on the `@Settings` property.

            ## Example

            ```swift
            # alula.yaml
            mail:
              host: smtp.example.com
              from: ${MAIL_FROM}
            ```

            ## Related

            ALU-CONFIG-5001, ALU-CONFIG-5006.

            """##,
        "ALU-CONFIG-5005": ##"""
            # ALU-CONFIG-5005: A configuration prefix that cannot name environment variables

            **Severity:** error

            ## Meaning

            `Configuration.load(prefix:)` is given a prefix with characters other than
            lowercase ASCII letters, digits and underscores, or one that does not start
            with a letter.

            ## Why Alula rejects it

            The prefix names the base file (`<prefix>.yaml`) and, uppercased, prefixes
            every environment variable that overrides it: `MYAPP_SERVER_PORT`. A prefix
            like `My-App` gives `MY-APP_SERVER_PORT`, which most shells cannot set.
            `Configuration.load` traps on it at startup; the build says so first.

            ## Fixes

            1. Use lowercase letters, digits and underscores: `Configuration.load(prefix: "my_app")`.

            ## Related

            ALU-CONFIG-5006.

            """##,
        "ALU-CONFIG-5006": ##"""
            # ALU-CONFIG-5006: The build could not check configuration keys

            **Severity:** warning

            ## Meaning

            The build checks every configuration key without a default against the base
            configuration file, and this time it could not:

            - the base file (`alula.yaml`, or `<prefix>.yaml`) is not in the package;
            - the prefix passed to `Configuration.load` is not a string literal;
            - the target loads configuration with more than one prefix.

            ## Why Alula rejects it

            The keys are still checked — at startup, which is later than it needs to be.
            The warning exists because a check that silently does not run is worse than
            none: it teaches you to trust it.

            ## Fixes

            1. Add the base file at the package root.
            2. Pass the prefix as a literal: `Configuration.load(prefix: "relay")`.
            3. Load configuration with one prefix.

            ## Related

            ALU-CONFIG-5004, ALU-CONFIG-5005.

            """##,
        "ALU-CONFIG-5007": ##"""
            # ALU-CONFIG-5007: The base configuration file does not parse

            **Severity:** error

            ## Meaning

            The base configuration file is not valid YAML, or could not be read. The
            diagnostic points at the line and column the parser stopped at.

            ## Why Alula rejects it

            The build reads the file to check keys, with the same parser the
            application uses at startup — so a file the build cannot read is one the
            application cannot either.

            ## Common causes

            - Inconsistent indentation.
            - A tab used for indentation.

            ## Fixes

            1. Fix the YAML at the reported position.

            ## Related

            ALU-CONFIG-5004.

            """##,
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
        "ALU-DI-1015": ##"""
            # ALU-DI-1015: Two @Inject properties of one type

            **Severity:** error

            ## Meaning

            A `@Component`, `@Controller` or `@Middleware` type has two `@Inject`
            properties of the same type, and nothing tells them apart.

            ## Why Alula rejects it

            Composition wires by type. Two properties of one type would both receive
            the same value — or, if you meant two different providers, one of them
            would silently get the wrong one.

            ## Common causes

            - Two data sources of one type, one meant for a replica.
            - A copied property that was meant to be renamed or retyped.

            ## Fixes

            1. If you meant two providers, name one of them: `@Inject(from: ReplicaModule.self)`.
            2. Give the values distinct types — a small wrapper struct is enough.
            3. If both name the same provider, delete one; they would hold the same value.

            ## Example

            ```swift
            @Inject var primary: PostgresDataSource
            @Inject(from: ReplicaDataModule.self) var replica: PostgresDataSource
            ```

            ## Related

            ALU-DI-1002, ALU-DI-1007.

            """##,
        "ALU-DI-1016": ##"""
            # ALU-DI-1016: An @Inject or @ConfigValue property has no written type

            **Severity:** error

            ## Meaning

            An `@Inject` or `@ConfigValue` property is declared without a type
            annotation, e.g. `@Inject var mailer = SMTPMailer()`.

            ## Why Alula rejects it

            Injection resolves by the static type as written. Without an annotation
            there is nothing for the generated initializer to ask for.

            ## Fixes

            1. Write the type: `@Inject var mailer: Mailer`.
            2. If the property is not meant to be injected, remove the attribute.

            ## Example

            ```swift
            @Inject var mailer: Mailer
            @ConfigValue("server.port") var port: Int
            ```

            ## Related

            ALU-DI-1011, ALU-DI-1019.

            """##,
        "ALU-DI-1017": ##"""
            # ALU-DI-1017: A stored property the generated initializer does not assign

            **Severity:** error

            ## Meaning

            A `@Component`, `@Controller` or `@Middleware` type has a stored property
            that is neither `@Inject` nor `@ConfigValue` and has no default value.

            ## Why Alula rejects it

            The macro generates the type's initializer, and that initializer assigns
            only injected and configured properties. Any other stored property needs a
            value of its own, or the type cannot be initialized.

            ## Common causes

            - A dependency that was meant to be `@Inject`.
            - Per-instance state added without a starting value.

            ## Fixes

            1. Mark it `@Inject` if composition should supply it.
            2. Give it a default value: `var retries = 3`.
            3. Make it computed if it derives from other properties.

            ## Example

            ```swift
            @Service
            struct Reports {
                @Inject var store: ReportStore
                let pageSize = 50
            }
            ```

            ## Related

            ALU-DI-1016.

            """##,
        "ALU-DI-1018": ##"""
            # ALU-DI-1018: @Component on something other than a struct or final class

            **Severity:** error

            ## Meaning

            `@Component`, `@Service` or `@Repository` is attached to a non-final class,
            an enum, an actor, a protocol or an extension.

            ## Why Alula rejects it

            The macro generates an initializer and a registration for the type. A
            subclass could override what the registration relies on, and the other
            declarations have no initializer for the macro to generate. A struct or a
            `final class` is the shape composition can build.

            ## Common causes

            - A class written without `final`.

            ## Fixes

            1. Mark the class `final` (the build offers this as a fix-it).
            2. Make it a struct.

            ## Example

            ```swift
            @Service
            final class Billing { … }
            ```

            ## Related

            ALU-WEB-2003.

            """##,
        "ALU-DI-1019": ##"""
            # ALU-DI-1019: @Inject or @ConfigValue on something other than a stored instance property

            **Severity:** error

            ## Meaning

            `@Inject` or `@ConfigValue` is attached to a static property, a computed
            property, a property with an initial value, or something that is not a
            property at all.

            ## Why Alula rejects it

            The generated initializer assigns these properties when the instance is
            built. A static property has no instance; a computed one has no storage;
            an initial value would be overwritten, so it would only mislead.

            ## Fixes

            1. Make it a stored instance property with a written type and no initial value.
            2. For a static or computed value, drop the attribute and set it where it is used.

            ## Example

            ```swift
            @Inject var clock: Clock                 // right
            @Inject static var clock: Clock          // ALU-DI-1019
            @Inject var clock: Clock = SystemClock() // ALU-DI-1019
            ```

            ## Related

            ALU-DI-1016.

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
        "ALU-SCHED-9001": ##"""
            # ALU-SCHED-9001: A cron expression or time zone that does not parse

            **Severity:** error

            ## Meaning

            A `@Scheduled` cron expression is malformed, or its time zone is not an
            IANA identifier.

            ## Why Alula rejects it

            Cron expressions are checked at build time so that a schedule that would
            never fire, or would fire at the wrong moment, is caught before deploy. An
            unknown time zone would fall back to GMT at runtime without a word.

            ## Common causes

            - A field out of range, such as hour `24` or month `13`.
            - A time zone written with spaces: "America/New York" instead of "America/New_York".

            ## Fixes

            1. Fix the expression as the message says. Six fields (seconds first) or the classic five.
            2. Use an IANA identifier such as "America/New_York", "Europe/London" or "UTC".

            ## Example

            ```swift
            @Scheduled("0 0 3 * * *", timeZone: "America/New_York")
            func nightly() async throws { … }
            ```

            ## Related

            ALU-SCHED-9003.

            """##,
        "ALU-SCHED-9002": ##"""
            # ALU-SCHED-9002: @Scheduled with no schedule, or with two

            **Severity:** error

            ## Meaning

            A `@Scheduled` attribute gives neither a cron expression nor an `every:`
            interval, or gives both.

            ## Why Alula rejects it

            A job needs exactly one description of when it runs. With none it would
            never run; with two, one would be ignored.

            ## Fixes

            1. Give a cron expression: `@Scheduled("0 0 3 * * *")`.
            2. Or an interval: `@Scheduled(every: .minutes(5))`.
            3. Not both.

            ## Example

            ```swift
            @Scheduled(every: .minutes(5))
            func sweep() async throws { … }
            ```

            ## Related

            ALU-SCHED-9001.

            """##,
        "ALU-SCHED-9003": ##"""
            # ALU-SCHED-9003: A @Scheduled argument that is not a literal

            **Severity:** error

            ## Meaning

            A `@Scheduled` cron expression, time zone or `onEveryNode:` value is a
            variable or an expression.

            ## Why Alula rejects it

            Schedules are checked at build time, from the source. A value known only at
            runtime cannot be checked.

            ## Fixes

            1. Write the value as a literal.
            2. For a schedule only known at runtime, build a `ScheduledJobRegistration` value instead.

            ## Example

            ```swift
            @Scheduled("0 */15 * * * *", onEveryNode: false)
            ```

            ## Related

            ALU-SCHED-9001.

            """##,
        "ALU-SCHED-9004": ##"""
            # ALU-SCHED-9004: @Scheduled on a method Alula cannot run as a job

            **Severity:** error

            ## Meaning

            `@Scheduled` is on something that is not a method, on a method that takes
            parameters or returns a value, or appears twice on one method.

            ## Why Alula rejects it

            The scheduler calls the job with nothing and reads nothing back: there is
            no caller to supply arguments or to use a result. A job is named after its
            method, so two schedules on one method would collide rather than both run.

            ## Fixes

            1. Take no parameters; inject what the job needs into the enclosing type.
            2. Return `Void`, and record results where they are needed.
            3. Split two schedules across two methods, or declare the extra one as a `ScheduledJobRegistration` value.

            ## Example

            ```swift
            @Scheduler
            struct Maintenance {
                @Inject var store: SessionStore
                @Scheduled(every: .hours(1)) func purge() async throws { try await store.purgeExpired() }
            }
            ```

            ## Related

            ALU-SCHED-9005.

            """##,
        "ALU-SCHED-9005": ##"""
            # ALU-SCHED-9005: @Scheduler on something that schedules nothing

            **Severity:** error

            ## Meaning

            `@Scheduler` is attached to something that is not a class or struct, or to
            a type with no `@Scheduled` methods.

            ## Why Alula rejects it

            `@Scheduler` exists to register the type's scheduled jobs. With none, it
            registers nothing — usually a sign the jobs were removed or never marked.

            ## Fixes

            1. Add a `@Scheduled` method.
            2. If this is an ordinary component, use `@Component` instead.

            ## Related

            ALU-SCHED-9004.

            """##,
        "ALU-SEC-6001": ##"""
            # ALU-SEC-6001: A route requires roles but authenticates no one

            **Severity:** error

            ## Meaning

            A route requires roles but runs on the `.public` lane, which establishes no
            principal.

            ## Why Alula rejects it

            A role check needs someone to check. On a public lane every request is
            anonymous, so every request would be rejected — the route could never
            succeed.

            ## Common causes

            - A route marked `pipelines: [.public]` that kept its `roles:`.

            ## Fixes

            1. Put the route on a lane that authenticates.
            2. Drop the roles if the route is meant to be public.

            ## Example

            ```swift
            @GetRoute("/invoices", pipelines: [.authenticated], roles: [AppRole.billing])
            ```

            ## Related

            ALU-WEB-2008.

            """##,
        "ALU-WEB-2001": ##"""
            # ALU-WEB-2001: Two handlers for one method and path

            **Severity:** error

            ## Meaning

            Two route handlers answer the same HTTP method and path.

            ## Why Alula rejects it

            A router can dispatch a request to only one handler. Keeping whichever was
            registered last would make routing depend on declaration order, and the
            other handler would be dead code no one is told about.

            ## Common causes

            - A handler copied to start a new one, with the path left unchanged.

            ## Fixes

            1. Change one handler's method or path.
            2. Delete the handler you no longer need.

            ## Example

            ```swift
            @GetRoute("/users/:id") func show(_ context: RequestContext, id: UUID) …
            @GetRoute("/users/:id") func detail(_ context: RequestContext, id: UUID) … // ALU-WEB-2001
            ```

            ## Related

            ALU-WEB-2004.

            """##,
        "ALU-WEB-2002": ##"""
            # ALU-WEB-2002: A route handler parameter Alula cannot bind

            **Severity:** error

            ## Meaning

            A route handler has a parameter Alula has no way to fill. Alula binds:

            - `_ context: RequestContext`, always the first parameter;
            - a path parameter, labelled after its `:segment`;
            - `body:`, decoded from the request body (once);
            - `query:`, decoded from the query string (once).

            ## Why Alula rejects it

            The generated route calls your handler with values it read from the
            request. A parameter matching none of those sources would have nothing to
            be called with.

            ## Common causes

            - An unlabelled parameter meant as the body.
            - A path parameter label that does not match its segment (`id:` for `:userID`).
            - A `body:` on a WebSocket upgrade — an upgrade request has no body.
            - A path segment named `:body` or `:query`, which collides with those labels.

            ## Fixes

            1. Label the body `body:`.
            2. Name the parameter after its segment, or rename the segment.
            3. Load domain objects from the id yourself: take `id: UUID`, not `user: User`.
            4. Read a colliding segment explicitly: `context.pathParam("body", as: String.self)`.

            ## Example

            ```swift
            @GetRoute("/users/:id")
            func show(_ context: RequestContext, id: UUID) async throws -> User
            ```

            ## Related

            ALU-WEB-2006.

            """##,
        "ALU-WEB-2003": ##"""
            # ALU-WEB-2003: @Controller or @Middleware on something other than a struct or final class

            **Severity:** error

            ## Meaning

            `@Controller` or `@Middleware` is attached to a non-final class, an enum,
            an actor, a protocol or an extension.

            ## Why Alula rejects it

            The macro generates an initializer and a route (or middleware) factory for
            the type. A subclass could override the handlers the route table points at,
            and the other declarations have no initializer to generate.

            ## Common causes

            - A class written without `final`.

            ## Fixes

            1. Mark the class `final` (the build offers this as a fix-it).
            2. Make it a struct — the usual choice for a controller, which is built per request.

            ## Example

            ```swift
            @Controller("/users")
            struct UsersController { … }
            ```

            ## Related

            ALU-DI-1018.

            """##,
        "ALU-WEB-2004": ##"""
            # ALU-WEB-2004: A malformed route path

            **Severity:** error

            ## Meaning

            A route or controller path is not a valid Alula path. A path must:

            - start with `/`;
            - name every `:parameter` segment, and each only once;
            - use `**` only as the last segment;
            - contain no quote or backslash.

            ## Why Alula rejects it

            The route table is built at compile time. A malformed path would either
            never match or match something other than what it says.

            ## Fixes

            1. Fix the path as the message says.
            2. Percent-encode a quote or backslash that is genuinely part of the path.

            ## Example

            ```swift
            @Controller("/users")          // not "users"
            @GetRoute("/:id/files/**")     // ** last
            ```

            ## Related

            ALU-WEB-2001, ALU-WEB-2005.

            """##,
        "ALU-WEB-2005": ##"""
            # ALU-WEB-2005: A route path that is not a string literal

            **Severity:** error

            ## Meaning

            A `@Controller` or route attribute's path is a variable, an expression, or
            an interpolated string.

            ## Why Alula rejects it

            The route table is built at compile time, from the source. A path known
            only at runtime cannot be checked for conflicts, cannot appear in
            `alula routes` or the OpenAPI document, and cannot be validated.

            ## Fixes

            1. Write the path as a plain string literal.
            2. For a route that really is only known at runtime, declare a `RouteRegistration` value from a module.

            ## Example

            ```swift
            @GetRoute("/health")           // not @GetRoute(healthPath)
            ```

            ## Related

            ALU-WEB-2004.

            """##,
        "ALU-WEB-2006": ##"""
            # ALU-WEB-2006: A route handler declared in a way Alula cannot call

            **Severity:** error

            ## Meaning

            A route handler is `static`, `mutating`, or is a WebSocket upgrade that
            does not return a `WebSocketUpgradeHandler`.

            ## Why Alula rejects it

            The generated route builds a controller for each request and calls the
            handler on that instance. A static method has no instance; a mutating one
            would change a controller discarded right after; an upgrade route needs a
            handler to hand the connection to.

            ## Fixes

            1. Make the handler an instance method.
            2. Drop `mutating`, and keep state in an injected component or on the `RequestContext`.
            3. Return a `WebSocketUpgradeHandler` from an upgrade route.

            ## Example

            ```swift
            @GetRoute("/stats")
            func stats(_ context: RequestContext) async throws -> Stats
            ```

            ## Related

            ALU-WEB-2002.

            """##,
        "ALU-WEB-2007": ##"""
            # ALU-WEB-2007: A route attribute outside a @Controller

            **Severity:** error

            ## Meaning

            A route attribute such as `@GetRoute` is on something that is not a
            method, or on a method whose type is not a `@Controller`.

            ## Why Alula rejects it

            `@Controller` reads the route attributes of its methods; nothing else
            does. A route anywhere else would silently never exist.

            ## Common causes

            - `@Controller` forgotten on the type.
            - The handler moved into an extension, which the controller does not scan.

            ## Fixes

            1. Add `@Controller` to the type that declares the method.
            2. Move the handler into the controller's main declaration.
            3. Declare the route as a `RouteRegistration` value from a module.

            ## Example

            ```swift
            @Controller("/users")
            struct UsersController {
                @GetRoute("/") func list(_ context: RequestContext) async throws -> [User] { … }
            }
            ```

            ## Related

            ALU-WEB-2003.

            """##,
        "ALU-WEB-2008": ##"""
            # ALU-WEB-2008: A route's pipelines drop its controller's authentication

            **Severity:** warning

            ## Meaning

            A route's `pipelines:` argument leaves out a lane its controller uses to
            authenticate, so the route runs without authentication.

            ## Why Alula rejects it

            A route's `pipelines:` replaces the controller's rather than adding to it —
            so a route that meant to add a lane can quietly lose authentication. It is
            a warning because a public route inside an authenticated controller is
            legitimate; the build asks you to say so.

            ## Common causes

            - Adding a lane to one route, expecting the controller's lanes to remain.

            ## Fixes

            1. List the controller's authenticating lane too.
            2. If the route is meant to be public, write `pipelines: [.public]` — that records the decision and silences the warning.

            ## Example

            ```swift
            @Controller("/account", pipelines: [.authenticated])
            struct AccountController {
                @GetRoute("/export", pipelines: [.authenticated, "audited"]) …
                @GetRoute("/terms", pipelines: [.public]) …
            }
            ```

            ## Related

            ALU-SEC-6001.

            """##,
        "ALU-WEB-2009": ##"""
            # ALU-WEB-2009: A route runs through a lane nothing declares

            **Severity:** warning

            ## Meaning

            A route's (or its controller's) `pipelines:` names a lane — `"audit"` — that
            no module declares with `MiddlewareRegistration.lane(_:_:)`.

            ## Why Alula rejects it

            Dispatch is built from the declared lanes, and building it fails on a route
            that names one it cannot find — at startup. It is a warning rather than an
            error because a lane can be declared by a module the build tool cannot see,
            such as one registered from a computed value.

            ## Common causes

            - A typo in the lane name.
            - The module that declares the lane is not in `modules:`.

            ## Fixes

            1. Declare the lane in a module: `MiddlewareRegistration.lane("audit", [AuditMiddleware.self])`. An empty list is legal.
            2. Correct the name, or remove the lane from the route's pipelines.

            ## Example

            ```swift
            @Controller("/admin", pipelines: [.authenticated, "audit"])
            ```

            ## Related

            ALU-WEB-2008.

            """##,
    ]
}
