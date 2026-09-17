// @Settings expansion fixtures — normative, same discipline as
// MacroFixtureTests: these expected-output strings are the specification.

import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

@testable import FlightCoreMacrosImpl

private let settingsMacros: [String: MacroSpec] = [
    "Settings": MacroSpec(type: SettingsMacro.self, conformances: ["CustomStringConvertible"]),
    "ConfigValue": MacroSpec(type: ConfigValueMacro.self),
    "Secret": MacroSpec(type: SecretMacro.self),
    "Inject": MacroSpec(type: InjectMacro.self),
]

@Suite("@Settings expansion")
struct SettingsMacroFixtureTests {

    @Test("every property optional: one getIfPresent-or-default line each, kebab-cased key")
    func allOptional() {
        assertMacroExpansion(
            """
            @Settings("auth")
            struct AuthSettings {
                var issuer: String = "myapp"
                var tokenLifetimeHours: Int = 12
            }
            """,
            expandedSource: """
                struct AuthSettings {
                    var issuer: String = "myapp"
                    var tokenLifetimeHours: Int = 12

                    init(_flightConfiguration configuration: FlightCore.Configuration) throws {
                        self.issuer = try configuration.getIfPresent("auth.issuer", as: String.self) ?? ("myapp")
                        self.tokenLifetimeHours = try configuration.getIfPresent("auth.token-lifetime-hours", as: Int.self) ?? (12)
                    }
                }
                """,
            macroSpecs: settingsMacros
        )
    }

    @Test("a property with no default is required, and uses get(_:) not getIfPresent")
    func requiredProperty() {
        assertMacroExpansion(
            """
            @Settings("auth")
            struct AuthSettings {
                var signingKey: String
            }
            """,
            expandedSource: """
                struct AuthSettings {
                    var signingKey: String

                    init(_flightConfiguration configuration: FlightCore.Configuration) throws {
                        self.signingKey = try configuration.get("auth.signing-key", as: String.self)
                    }
                }
                """,
            macroSpecs: settingsMacros
        )
    }

    @Test("a validate() method is called after construction, inside the registration thunk")
    func validateIsCalled() {
        // The thunk this test is named for is gone with the container;
        // validation moved *into* the generated initializer, which is
        // strictly earlier — a bad value now fails composition rather than
        // failing at container freeze. The guarantee the fixture exists for
        // is unchanged: `validate()` runs, and it runs after every field is
        // bound, never before.
        assertMacroExpansion(
            """
            @Settings("auth")
            struct AuthSettings {
                var signingKey: String

                func validate() throws {}
            }
            """,
            expandedSource: """
                struct AuthSettings {
                    var signingKey: String

                    func validate() throws {}

                    init(_flightConfiguration configuration: FlightCore.Configuration) throws {
                        self.signingKey = try configuration.get("auth.signing-key", as: String.self)
                        try validate()
                    }
                }
                """,
            macroSpecs: settingsMacros
        )
    }

    @Test("a static validate() does not count — only an instance method runs")
    func staticValidateIsIgnored() {
        assertMacroExpansion(
            """
            @Settings("auth")
            struct AuthSettings {
                var signingKey: String

                static func validate() throws {}
            }
            """,
            expandedSource: """
                struct AuthSettings {
                    var signingKey: String

                    static func validate() throws {}

                    init(_flightConfiguration configuration: FlightCore.Configuration) throws {
                        self.signingKey = try configuration.get("auth.signing-key", as: String.self)
                    }
                }
                """,
            macroSpecs: settingsMacros
        )
    }

    @Test("@ConfigValue overrides the derived key; its own default: argument supplies the fallback")
    func explicitKeyOverride() {
        // Not a property-level initializer: @ConfigValue's own peer macro
        // independently rejects one ("the generated initializer supplies the
        // value at construction") whether or not @Settings is also attached —
        // that rule is unconditional, so overriding a key inside @Settings
        // uses exactly the same default: argument @ConfigValue uses
        // everywhere else.
        assertMacroExpansion(
            """
            @Settings("auth")
            struct AuthSettings {
                @ConfigValue("legacy.audience", default: "myapp-web") var audience: String
            }
            """,
            expandedSource: """
                struct AuthSettings {
                    var audience: String

                    init(_flightConfiguration configuration: FlightCore.Configuration) throws {
                        self.audience = try configuration.getIfPresent("legacy.audience", as: String.self) ?? ("myapp-web")
                    }
                }
                """,
            macroSpecs: settingsMacros
        )
    }

    @Test("@Secret redacts that field in the generated description; other fields render plainly")
    func secretRedaction() {
        assertMacroExpansion(
            """
            @Settings("auth")
            struct AuthSettings {
                var issuer: String = "myapp"
                @Secret var signingKey: String
            }
            """,
            expandedSource: """
                struct AuthSettings {
                    var issuer: String = "myapp"
                    var signingKey: String

                    init(_flightConfiguration configuration: FlightCore.Configuration) throws {
                        self.issuer = try configuration.getIfPresent("auth.issuer", as: String.self) ?? ("myapp")
                        self.signingKey = try configuration.get("auth.signing-key", as: String.self)
                    }

                    public var description: String {
                        "AuthSettings(issuer: \\(String(reflecting: self.issuer)), signingKey: \\"<REDACTED>\\")"
                    }
                }

                extension AuthSettings: Swift.CustomStringConvertible {
                }
                """,
            macroSpecs: settingsMacros
        )
    }

    @Test("a public type's registration thunk is public")
    func publicAccessMatchesType() {
        // The thunk is gone; the initializer inherited its job, and with it
        // the access rule this fixture was written to hold. That rule was
        // *broken* between the container's removal and 24d5acb: the access
        // level was computed and dropped, so every @Settings type got an
        // `internal` init and a public settings type in a library could not
        // be constructed from the module that imports it — while the
        // registration generator hard-errors unless a cross-module scanned
        // component is public. This expectation is the regression guard for
        // that fix.
        assertMacroExpansion(
            """
            @Settings("web")
            public struct WebSettings {
                var maxRequestBodyBytes: Int = 1_048_576
            }
            """,
            expandedSource: """
                public struct WebSettings {
                    var maxRequestBodyBytes: Int = 1_048_576

                    public init(_flightConfiguration configuration: FlightCore.Configuration) throws {
                        self.maxRequestBodyBytes = try configuration.getIfPresent("web.max-request-body-bytes", as: Int.self) ?? (1_048_576)
                    }
                }
                """,
            macroSpecs: settingsMacros
        )
    }

    @Test("a computed property is left alone — not treated as a config binding")
    func computedPropertyIsIgnored() {
        assertMacroExpansion(
            """
            @Settings("auth")
            struct AuthSettings {
                var tokenLifetime: Duration = .hours(12)
                var tokenLifetimeSeconds: Double { tokenLifetime.components.seconds.magnitude.description.isEmpty ? 0 : 0 }
            }
            """,
            expandedSource: """
                struct AuthSettings {
                    var tokenLifetime: Duration = .hours(12)
                    var tokenLifetimeSeconds: Double { tokenLifetime.components.seconds.magnitude.description.isEmpty ? 0 : 0 }

                    init(_flightConfiguration configuration: FlightCore.Configuration) throws {
                        self.tokenLifetime = try configuration.getIfPresent("auth.token-lifetime", as: Duration.self) ?? (.hours(12))
                    }
                }
                """,
            macroSpecs: settingsMacros
        )
    }
}

// MARK: - Diagnostics

/// The member role and the extension role decide independently: the compiler
/// invokes the extension role whatever the member role did, and a diagnostic
/// emitted from the member role does not suppress it. That used to be visible
/// here as a `_FlightRegistrable` conformance on every invalid case below,
/// pinned deliberately to match `@Component`/`@Repository`'s established
/// behavior. With the container's marker protocol gone, `@Settings` has only
/// one conformance left to emit — `CustomStringConvertible`, and only when a
/// `@Secret` field makes a redacting description necessary — so the invalid
/// cases below now show no extension at all. The independence is unchanged;
/// there is simply nothing unconditional left for it to produce.
@Suite("@Settings diagnostics")
struct SettingsMacroDiagnosticTests {

    @Test("no namespace argument is an error")
    func missingNamespace() {
        assertMacroExpansion(
            """
            @Settings
            struct AuthSettings {
                var issuer: String = "myapp"
            }
            """,
            expandedSource: """
                struct AuthSettings {
                    var issuer: String = "myapp"
                }
                """,
            diagnostics: [
                DiagnosticSpec(message: "@Settings requires a namespace, as a string literal, e.g. @Settings(\"auth\").", line: 1, column: 1)
            ],
            macroSpecs: settingsMacros
        )
    }

    @Test("@Inject inside @Settings is refused")
    func injectRefused() {
        assertMacroExpansion(
            """
            @Settings("auth")
            struct AuthSettings {
                @Inject var logger: AppLogger
            }
            """,
            expandedSource: """
                struct AuthSettings {
                    var logger: AppLogger

                    init(_flightConfiguration configuration: FlightCore.Configuration) throws {
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Inject is not valid inside @Settings — settings hold configuration only. Put dependencies in a @Service or @Component instead.",
                    line: 3, column: 5)
            ],
            macroSpecs: settingsMacros
        )
    }

    @Test("an Optional property is refused, with a fix in the message")
    func optionalRefused() {
        assertMacroExpansion(
            """
            @Settings("auth")
            struct AuthSettings {
                var nickname: String?
            }
            """,
            expandedSource: """
                struct AuthSettings {
                    var nickname: String?

                    init(_flightConfiguration configuration: FlightCore.Configuration) throws {
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "'nickname' may not be Optional. Give it a concrete default instead of allowing absence — @Settings binds a value once, at bootstrap, and a key that may or may not exist has no single answer for 'what did we configure'.",
                    line: 3, column: 5)
            ],
            macroSpecs: settingsMacros
        )
    }

    @Test("a let with a default must be var, since the generated init overrides it")
    func letWithDefaultRefused() {
        assertMacroExpansion(
            """
            @Settings("auth")
            struct AuthSettings {
                let issuer: String = "myapp"
            }
            """,
            expandedSource: """
                struct AuthSettings {
                    let issuer: String = "myapp"

                    init(_flightConfiguration configuration: FlightCore.Configuration) throws {
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "'issuer' has a default value, so it must be 'var' — the generated initializer assigns it when configuration supplies a value, overriding the default.",
                    line: 3, column: 5)
            ],
            macroSpecs: settingsMacros
        )
    }

    @Test("attaching to a non-final class is refused")
    func nonFinalClassRefused() {
        assertMacroExpansion(
            """
            @Settings("auth")
            class AuthSettings {
                var issuer: String = "myapp"
            }
            """,
            expandedSource: """
                class AuthSettings {
                    var issuer: String = "myapp"
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Settings requires a final class (or a struct). Mark 'AuthSettings' final.",
                    line: 2, column: 7)
            ],
            macroSpecs: settingsMacros
        )
    }
}
