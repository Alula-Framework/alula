import AlulaDiagnostics
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

@testable import AlulaCoreMacrosImpl

// One case per code the component macros own that no other fixture
// exercises, so the coverage metric counts it as proven. `@Inject` and
// `@ConfigValue` are left unregistered: the diagnostic under test is
// @Service's, not the property markers'.
private let serviceOnly: [String: MacroSpec] = [
    "Service": MacroSpec(type: ServiceMacro.self)
]

@Suite("component macro diagnostic codes")
struct CodedDiagnosticTests {
    @Test("an untyped @Inject is ALU-DI-1016")
    func untypedInjection() {
        assertMacroExpansion(
            """
            @Service
            struct Reminders {
                @Inject var clock
            }
            """,
            expandedSource: """
                struct Reminders {
                    @Inject var clock

                    init() {
                    }
                }
                """,
            // One error. The property also has no default, and used to be
            // reported a second time for that (ALU-DI-1017).
            diagnostics: [
                DiagnosticSpec.coded(.untypedInjection,
                    message: "@Inject/@ConfigValue properties need an explicit type annotation — injection resolves by static type.",
                    line: 3, column: 5)
            ],
            macroSpecs: serviceOnly)
    }

    @Test("a static @Inject is ALU-DI-1019")
    func staticInjection() {
        assertMacroExpansion(
            """
            @Service
            struct Reminders {
                @Inject static var clock: Clock
            }
            """,
            expandedSource: """
                struct Reminders {
                    @Inject static var clock: Clock

                    init() {
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec.coded(.invalidInjectionTarget,
                    message: "Injection is per-instance: the generated initializer assigns the properties, and a static property has no instance to belong to. Make it an instance property, or set it explicitly where it is used.",
                    line: 3, column: 5)
            ],
            macroSpecs: serviceOnly)
    }

    @Test("a @ConfigValue without a key is ALU-CONFIG-5001")
    func configValueWithoutKey() {
        assertMacroExpansion(
            """
            @Service
            struct Server {
                @ConfigValue var port: Int
            }
            """,
            expandedSource: """
                struct Server {
                    @ConfigValue var port: Int

                    init() {
                    }
                }
                """,
            // One error, for the same reason as the untyped case above.
            diagnostics: [
                DiagnosticSpec.coded(.configValueWithoutKey,
                    message: "@ConfigValue requires a key, e.g. @ConfigValue(\"server.port\").",
                    line: 3, column: 5)
            ],
            macroSpecs: serviceOnly)
    }
}
