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

    @Test("repository stereotype — and @Repository takes no arguments")
    func repositoryStereotype() {
        // This fixture used to spell `@Repository(qualifier: "replica")`, to
        // document an argument that parsed and was then dropped. In 0.20.0 the
        // argument is gone from the macro declaration, so the shape it pinned
        // no longer exists: the bare attribute is the only one there is.
        //
        // Where the *rejection* is pinned is deliberately elsewhere. An
        // argument the declaration does not have fails to type-check before
        // expansion begins, so `assertMacroExpansion` — which runs the macro
        // implementation against source text, with no declaration to check
        // against — structurally cannot observe it. The build error naming the
        // migration is the generator's, and FlightRegistrationGenTests'
        // `removedScopeArgumentDiagnosed` / `removedQualifierArgumentDiagnosed`
        // pin it there.
        assertMacroExpansion(
            """
            @Repository
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

    // MARK: Fixture 6a — two @Inject of one type: refuse

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
                        "Two @Inject properties of type 'DataSource'. Composition wires by type, so nothing distinguishes them. Name the provider on one of them — @Inject(from: SomeModule.self) — or give them distinct types.",
                    line: 4,
                    column: 5
                )
            ],
            macroSpecs: testMacros
        )
    }

    // MARK: Fixture 6b — the qualified spelling does not rescue 6a

    @Test("a qualified inject is refused too — the qualifier is gone")
    func qualifiedInjectIsRefusedToo() {
        // This fixture used to pin the *accepted* qualified shape: 6a refused
        // the bare pair, and adding `@Inject("primary")`/`@Inject("replica")`
        // made it legal. What it could never pin is whether those two then
        // resolved to two different instances — that is decided by
        // flight-registration-gen, which no macro-expansion fixture can
        // observe. The 2026-09-17 audit answered it: the generator keys root
        // parameters on type text, so the pair collapsed onto *one* instance.
        // The fixture was structurally unable to catch a live misbinding, and
        // documented the shape that caused it as correct.
        //
        // 0.20.0 removed the property-level qualifier rather than wiring it,
        // so the inverse is what is worth pinning: the qualified spelling is
        // refused exactly like the bare one. Same diagnostic, same site. The
        // silent misbinding is now a compile error.
        //
        // Note this fixture asserts more than the macro declaration does:
        // `@Inject("primary")` no longer type-checks at all, but
        // `assertMacroExpansion` runs the implementation against source text
        // with no declaration to check against, so what it sees is the
        // implementation ignoring the argument and refusing the pair.
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
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Two @Inject properties of type 'DataSource'. Composition wires by type, so nothing distinguishes them. Name the provider on one of them — @Inject(from: SomeModule.self) — or give them distinct types.",
                    line: 4,
                    column: 5
                )
            ],
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

    // MARK: Supplementary — @Component takes no arguments

    @Test("component takes no arguments")
    func componentTakesNoArguments() {
        // This fixture existed to say out loud that `@Component(qualifier:)`
        // expanded to nothing — the "shipped inert" shape — and to notice if
        // it were ever made to mean something again. 0.20.0 took the third
        // option and deleted it, so what is worth pinning now is the inverse:
        // the bare attribute is the whole surface, and an expansion that ever
        // starts *depending* on an argument would have to add one back here.
        //
        // The property-level `@Inject("name")` went in the same release: see
        // `ambiguousInjectIsCompileError`, where two properties of one type
        // are refused outright because nothing can tell them apart.
        assertMacroExpansion(
            """
            @Component
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
