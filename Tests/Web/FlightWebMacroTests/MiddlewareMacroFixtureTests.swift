// @Middleware expansion fixtures — same discipline as
// ControllerMacroFixtureTests: these expected strings are the spec.

import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

@testable import FlightCoreMacrosImpl
@testable import FlightWebMacrosImpl

// `FlightWeb.Middleware` is the one conformance left: the container's
// `_FlightRegistrable` marker protocol went with the container, so the
// extension role now emits exactly one extension, unconditionally.
private let testMacros: [String: MacroSpec] = [
    "Middleware": MacroSpec(
        type: MiddlewareMacro.self,
        conformances: ["FlightWeb.Middleware"]),
    "Inject": MacroSpec(type: InjectMacro.self),
]

@Suite("@Middleware expansion")
struct MiddlewareMacroFixtureTests {

    @Test("no dependencies: an empty resolving init, always .singleton and .middleware")
    func plainMiddleware() {
        // The scope and stereotype this test is named for are no longer in
        // the expansion at all — they were arguments to the container-era
        // register call, and a middleware is now built by the composition
        // root through the initializer below. The stereotype rides the
        // build-scanned descriptor instead. What the fixture still pins: a
        // dependency-free middleware gets a parameterless initializer (not
        // memberwise synthesis, which it would otherwise be relying on) and
        // the Middleware conformance.
        assertMacroExpansion(
            """
            @Middleware
            struct RequestTiming {
                func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }
            }
            """,
            expandedSource: """
                struct RequestTiming {
                    func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }

                    init() {
                    }
                }

                extension RequestTiming: FlightWeb.Middleware {
                }
                """,
            macroSpecs: testMacros
        )
    }

    @Test("@Inject dependencies resolve exactly like @Component")
    func withDependencies() {
        assertMacroExpansion(
            """
            @Middleware
            public struct Transactions {
                @Inject var sessions: SessionStore
                @Inject var settings: WebSettings
                func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }
            }
            """,
            expandedSource: """
                public struct Transactions {
                    var sessions: SessionStore
                    var settings: WebSettings
                    func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }

                    public init(sessions: SessionStore, settings: WebSettings) {
                        self.sessions = sessions
                        self.settings = settings
                    }
                }

                extension Transactions: FlightWeb.Middleware {
                }
                """,
            macroSpecs: testMacros
        )
    }

    @Test("no scope: or qualifier: argument is accepted — @Middleware takes none")
    func noArguments() {
        assertMacroExpansion(
            """
            @Middleware
            struct Plain {
                func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }
            }
            """,
            expandedSource: """
                struct Plain {
                    func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }

                    init() {
                    }
                }

                extension Plain: FlightWeb.Middleware {
                }
                """,
            macroSpecs: testMacros
        )
    }
}

@Suite("@Middleware diagnostics")
struct MiddlewareMacroDiagnosticTests {

    @Test("attaching to a non-final class is refused")
    func nonFinalClassRefused() {
        assertMacroExpansion(
            """
            @Middleware
            class RequestTiming {
                func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }
            }
            """,
            expandedSource: """
                class RequestTiming {
                    func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }
                }

                extension RequestTiming: FlightWeb.Middleware {
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Middleware requires a final class (or a struct). Mark 'RequestTiming' final.",
                    line: 2, column: 7)
            ],
            macroSpecs: testMacros
        )
    }

    @Test("an uninitialized non-injected property is rejected, naming the fix")
    func uninitializedStoredPropertyIsRejected() {
        assertMacroExpansion(
            """
            @Middleware
            struct RequestTiming {
                let label: String
                func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }
            }
            """,
            expandedSource: """
                struct RequestTiming {
                    let label: String
                    func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }
                }

                extension RequestTiming: FlightWeb.Middleware {
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Stored property 'label' of a @Middleware type needs a default value — the generated initializer assigns only @Inject/@ConfigValue properties.",
                    line: 3, column: 5)
            ],
            macroSpecs: testMacros
        )
    }

    @Test("two @Inject properties of the same type need distinct qualifiers")
    func ambiguousInjectIsRejected() {
        assertMacroExpansion(
            """
            @Middleware
            struct Fanout {
                @Inject var primary: Backend
                @Inject var secondary: Backend
                func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }
            }
            """,
            expandedSource: """
                struct Fanout {
                    var primary: Backend
                    var secondary: Backend
                    func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }
                }

                extension Fanout: FlightWeb.Middleware {
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Two @Inject properties of type 'Backend' require distinct explicit qualifiers, e.g. @Inject(\"primary\").",
                    line: 4, column: 5)
            ],
            macroSpecs: testMacros
        )
    }
}
