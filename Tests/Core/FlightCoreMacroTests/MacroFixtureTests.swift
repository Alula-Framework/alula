// §5.4 — the macro expansion spike, resolved as fixtures.
//
// These expected-output strings ARE the specification of Flight's macro
// expansions; the design doc's prose examples are illustrative, these are
// normative. Design decisions they pin (recorded in SPIKE-FINDINGS.md):
//
//  M-1  A component is constructed through a macro-generated initializer,
//       never through one it declares itself. The doc's `init() {}` alongside
//       non-optional @Inject stored properties cannot compile in real Swift —
//       exactly the kind of looks-obvious-doesn't-compile gap this fixture
//       process exists to catch. *Which* initializer that is has changed: the
//       container-era `init(_flight:)`, the `_flightRegister` thunk and the
//       `_FlightRegistrable` conformance all went with the container
//       (0.15.0–0.18.0). What remains is constructor injection — one
//       parameter per @Inject property — which the composition root calls.
//  F-6  Two @Inject properties of one type without distinct explicit
//       qualifiers are a compile error (fixture 6a) — Flight refuses to
//       guess positionally. With qualifiers the declaration is accepted
//       (6b); see that fixture for where the qualifier goes now, and for why
//       that is no longer the whole story.
//
// NOTE ON FIRST RUN: expected strings were written without a toolchain to
// verify against (see README). assertMacroExpansion output formatting
// (BasicFormat) may disagree on whitespace/indentation, not substance —
// expect one mechanical alignment pass, then these freeze.

import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

@testable import FlightCoreMacrosImpl

// MacroSpec (not a bare [String: Macro.Type]) so the harness knows the
// conformances `@attached(extension, conformances:)` declares — without it,
// the extension macro receives an empty `protocols` list and emits nothing,
// which diverges from real compilation (first-run finding; the runtime
// integration suite proves the compiler path emits the conformance).
//
// Only `@Settings` still declares an extension role, and only
// `CustomStringConvertible`: `@Component` and its stereotypes conform to
// nothing now, because the container's `_FlightRegistrable` marker protocol
// went with the container.
private let testMacros: [String: MacroSpec] = [
    "Component": MacroSpec(type: ComponentMacro.self),
    "Service": MacroSpec(type: ServiceMacro.self),
    "Repository": MacroSpec(type: RepositoryMacro.self),
    "Inject": MacroSpec(type: InjectMacro.self),
    "ConfigValue": MacroSpec(type: ConfigValueMacro.self),
    "Settings": MacroSpec(type: SettingsMacro.self, conformances: ["CustomStringConvertible"]),
    "Secret": MacroSpec(type: SecretMacro.self),
]

@Suite("macro fixture tests")
struct MacroFixtureTests {

    // MARK: Fixture 1 — a component with no dependencies

    @Test("plain component")
    func plainComponent() {
        assertMacroExpansion(
            """
            @Component
            final class ClockService {
                func now() -> Int { 0 }
            }
            """,
            expandedSource: """
                final class ClockService {
                    func now() -> Int { 0 }

                    init() {
                    }
                }
                """,
            macroSpecs: testMacros
        )
    }

    // MARK: Fixture 2 — a component with @Inject dependencies
    // (public type, so the generated initializer is access-matched — the
    // composition root that calls it is generated in another module)

    @Test("component with dependencies")
    func componentWithDependencies() {
        assertMacroExpansion(
            """
            @Component
            public final class UserService {
                @Inject let repository: UserRepository
                @Inject let logger: AppLogger
            }
            """,
            expandedSource: """
                public final class UserService {
                    let repository: UserRepository
                    let logger: AppLogger

                    public init(repository: UserRepository, logger: AppLogger) {
                        self.repository = repository
                        self.logger = logger
                    }
                }
                """,
            macroSpecs: testMacros
        )
    }

    // MARK: Stereotypes (§5.1.1) — identical expansion
    //
    // They always were identical but for the `stereotype:` tag on the
    // register call; with the register call gone the expansions are
    // byte-identical, and the stereotype rides the build-scanned descriptor
    // (which is what Actuator reads) instead. These two fixtures are
    // therefore what proves the stereotype does not accidentally start
    // changing generated code.

    @Test("service stereotype")
    func serviceStereotype() {
        assertMacroExpansion(
            """
            @Service
            final class BillingService {
                @Inject let repository: InvoiceRepository
            }
            """,
            expandedSource: """
                final class BillingService {
                    let repository: InvoiceRepository

                    init(repository: InvoiceRepository) {
                        self.repository = repository
                    }
                }
                """,
            macroSpecs: testMacros
        )
    }

    @Test("repository stereotype")
    func repositoryStereotype() {
        // Arguments compose exactly as on @Component — and, exactly as on
        // @Component, `qualifier:` is now parsed and then dropped
        // (ComponentMacro.swift:75). It is still accepted by the macro
        // declaration, so it cannot be a compile error here; it simply makes
        // no difference to the expansion. See `qualifiedInject` below.
        assertMacroExpansion(
            """
            @Repository(qualifier: "replica")
            public final class InvoiceRepository {
            }
            """,
            expandedSource: """
                public final class InvoiceRepository {

                    public init() {
                    }
                }
                """,
            macroSpecs: testMacros
        )
    }

    @Test("stereotype diagnostics name the attribute")
    func stereotypeDiagnosticsNameTheAttribute() {
        assertMacroExpansion(
            """
            @Repository
            class OpenRepository {
            }
            """,
            expandedSource: """
                class OpenRepository {
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Repository requires a final class (or a struct). Mark 'OpenRepository' final.",
                    line: 2,
                    column: 7
                )
            ],
            macroSpecs: testMacros
        )
    }
    // MARK: Fixture 5 — a scoped component

    @Test("scoped component")
    func scopedComponent() {
        assertMacroExpansion(
            """
            @Component
            final class RequestContext {
            }
            """,
            expandedSource: """
                final class RequestContext {

                    init() {
                    }
                }
                """,
            macroSpecs: testMacros
        )
    }

    // MARK: Fixture 6a — two @Inject of one type, no qualifiers: refuse

    @Test("ambiguous inject is compile error")
    func ambiguousInjectIsCompileError() {
        assertMacroExpansion(
            """
            @Component
            final class ReportService {
                @Inject var primary: DataSource
                @Inject var replica: DataSource
            }
            """,
            expandedSource: """
                final class ReportService {
                    var primary: DataSource
                    var replica: DataSource
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Two @Inject properties of type 'DataSource' require distinct explicit qualifiers, e.g. @Inject(\"primary\").",
                    line: 4,
                    column: 5
                )
            ],
            macroSpecs: testMacros
        )
    }

    // MARK: Fixture 6b — the qualified resolution

    @Test("qualified inject")
    func qualifiedInject() {
        // What the qualifier buys has moved, and this fixture can no longer
        // see all of it. Under the container the expansion carried it —
        // `container.resolve(DataSource.self, qualifier: "primary")` — so
        // pinning the expansion pinned the wiring. Constructor injection
        // carries the distinction in the *parameter name* instead, and the
        // macro drops the qualifier string on the floor (ComponentMacro.swift
        // :75, `_ = (scopeExpr, qualifierExpr, stereotypeArgument)`).
        //
        // Whether "primary" and "replica" then resolve to two different
        // registrations is decided by flight-registration-gen, which no
        // macro-expansion fixture can observe. The 2026-09-17 audit found
        // that it keys root parameters on type text, so these two properties
        // collapse onto one instance — a live defect this fixture is
        // structurally unable to catch. What it does still pin is that the
        // qualified shape is *accepted* (6a proves the unqualified one is
        // not) and that both properties become distinct parameters.
        assertMacroExpansion(
            """
            @Component
            final class ReportService {
                @Inject("primary") var primary: DataSource
                @Inject("replica") var replica: DataSource
            }
            """,
            expandedSource: """
                final class ReportService {
                    var primary: DataSource
                    var replica: DataSource

                    init(primary: DataSource, replica: DataSource) {
                        self.primary = primary
                        self.replica = replica
                    }
                }
                """,
            macroSpecs: testMacros
        )
    }

    // MARK: Supplementary — @ConfigValue expansion
    //
    // A @ConfigValue property is *not* a parameter: its value is a property
    // of the deployment, not of the call site. The configuration itself is
    // the parameter — `_flightConfiguration` — and only when the type reads
    // from it at all, which is why the dependency-free fixtures above get a
    // plain `init()`.

    @Test("config value")
    func configValue() {
        assertMacroExpansion(
            """
            @Component
            final class ServerSettings {
                @ConfigValue("server.port") let port: Int
            }
            """,
            expandedSource: """
                final class ServerSettings {
                    let port: Int

                    init(_flightConfiguration configuration: FlightCore.Configuration) throws {
                        self.port = try configuration.get("server.port", as: Int.self)
                    }
                }
                """,
            macroSpecs: testMacros
        )
    }

    // MARK: Supplementary — @ConfigValue with default: (Flight Config §5)
    //
    // Resolves through getIfPresent, not get(_:default:): absence applies the
    // default, but a present-and-malformed value still throws — failing
    // composition loudly instead of silently taking the default. The default
    // expression is parenthesized so low-precedence expressions cannot
    // rebind against `??`.

    @Test("config value with default")
    func configValueWithDefault() {
        assertMacroExpansion(
            """
            @Component
            final class PoolSettings {
                @ConfigValue("datasource.pool_size", default: 10) let poolSize: Int
            }
            """,
            expandedSource: """
                final class PoolSettings {
                    let poolSize: Int

                    init(_flightConfiguration configuration: FlightCore.Configuration) throws {
                        self.poolSize = try configuration.getIfPresent("datasource.pool_size", as: Int.self) ?? (10)
                    }
                }
                """,
            macroSpecs: testMacros
        )
    }

    // MARK: Supplementary — @Component qualifier argument

    @Test("component qualifier")
    func componentQualifier() {
        // Still spelled, still accepted by the macro declaration
        // (`Macros.swift`'s `qualifier: String? = nil`), and since the
        // register call went with the container it now makes no difference
        // whatsoever to the generated code. This fixture exists to say so
        // out loud: an argument that expands to nothing is the "shipped
        // inert" shape, and if it is ever made to mean something again, this
        // is the test that will notice.
        assertMacroExpansion(
            """
            @Component(qualifier: "primary")
            final class PrimarySource {
            }
            """,
            expandedSource: """
                final class PrimarySource {

                    init() {
                    }
                }
                """,
            macroSpecs: testMacros
        )
    }

    // MARK: Supplementary — diagnostics

    @Test("non final class is rejected")
    func nonFinalClassIsRejected() {
        assertMacroExpansion(
            """
            @Component
            class OpenService {
            }
            """,
            expandedSource: """
                class OpenService {
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Component requires a final class (or a struct). Mark 'OpenService' final.",
                    line: 2,
                    column: 7
                )
            ],
            macroSpecs: testMacros
        )
    }

    @Test("uninitialized stored property is rejected")
    func uninitializedStoredPropertyIsRejected() {
        // M-3: the generated initializer assigns only injected properties;
        // anything else stored needs a default. Without this diagnostic the
        // compile error points inside the macro expansion.
        assertMacroExpansion(
            """
            @Component
            final class Tracer {
                let id: Int
            }
            """,
            expandedSource: """
                final class Tracer {
                    let id: Int
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Stored property 'id' of a @Component type needs a default value — the generated initializer assigns only @Inject/@ConfigValue properties.",
                    line: 3,
                    column: 5
                )
            ],
            macroSpecs: testMacros
        )
    }
}
