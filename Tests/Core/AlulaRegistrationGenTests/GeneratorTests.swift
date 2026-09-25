import Foundation
import Testing

/// End-to-end tests for `alula-registration-gen`.
///
/// The generator is a build tool: its contract is a manifest in, a Swift file
/// and a set of compiler diagnostics out. These drive the real executable
/// against real source files, because that contract — not any internal
/// function — is what a broken build would break.
@Suite("alula-registration-gen")
struct GeneratorTests {

    // MARK: - Harness

    /// The built generator. Declaring the executable as a dependency of this
    /// test target is what guarantees it exists by the time these run.
    static let executable: URL = {
        // Walk up from this file until the directory holding Package.swift —
        // the package root — rather than counting directory levels. Counting
        // broke the moment the test target moved from Tests/X to Tests/Core/X,
        // and would break again on any future regrouping.
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Package.swift").path)
        {
            let parent = root.deletingLastPathComponent()
            precondition(
                parent.path != root.path,
                "no Package.swift above \(#filePath) — cannot locate the built generator")
            root = parent
        }
        root.appendPathComponent(".build")
        for configuration in ["debug", "release"] {
            let candidate =
                root
                .appendingPathComponent(configuration)
                .appendingPathComponent("alula-registration-gen")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        // Fall back to the arch-specific layout SwiftPM uses on Linux.
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) {
            for entry in entries {
                let candidate =
                    entry
                    .appendingPathComponent("debug")
                    .appendingPathComponent("alula-registration-gen")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return root.appendingPathComponent("debug/alula-registration-gen")
    }()

    struct Result {
        let exitCode: Int32
        let diagnostics: String
        let generated: String
    }

    /// Writes `sources` to a temporary target, runs the generator over them,
    /// and returns what it produced.
    /// `alulaYAML`, when given, is written as `alula.yaml` in the same
    /// workspace the sources land in (not added to `modules[0].files` — it
    /// is not Swift), and the workspace itself becomes `packageDirectory`
    /// unless the caller overrides it — the layout a real package actually
    /// has, source files and `alula.yaml` side by side.
    /// - Parameter configFiles: Extra files written beside the sources, by
    ///   name. `alulaYAML:` covers the default `alula.yaml`; this is for an
    ///   application that renamed its base layer with
    ///   `Configuration.load(prefix:)`, whose file the generator finds by
    ///   reading that argument out of the scanned source.
    func generate(
        _ sources: [String: String],
        targetModule: String = "AppModule",
        packageDirectory: String? = nil,
        alulaYAML: String? = nil,
        configFiles: [String: String] = [:],
        dependencyModules: [String: [String: String]] = [:]
    ) throws -> Result {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alulagen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        var paths: [String] = []
        for (name, contents) in sources.sorted(by: { $0.key < $1.key }) {
            let path = workspace.appendingPathComponent(name)
            try contents.write(to: path, atomically: true, encoding: .utf8)
            paths.append(path.path)
        }
        if let alulaYAML {
            try alulaYAML.write(
                to: workspace.appendingPathComponent("alula.yaml"), atomically: true,
                encoding: .utf8)
        }
        for (name, contents) in configFiles {
            try contents.write(
                to: workspace.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        // Other Swift modules the target links, each in its own directory.
        var modules: [[String: Any]] = [["name": targetModule, "files": paths]]
        for (module, files) in dependencyModules.sorted(by: { $0.key < $1.key }) {
            let directory = workspace.appendingPathComponent(module)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var modulePaths: [String] = []
            for (name, contents) in files.sorted(by: { $0.key < $1.key }) {
                let path = directory.appendingPathComponent(name)
                try contents.write(to: path, atomically: true, encoding: .utf8)
                modulePaths.append(path.path)
            }
            modules.append(["name": module, "files": modulePaths])
        }

        let output = workspace.appendingPathComponent("AlulaRegistrations.swift")
        var manifest: [String: Any] = [
            "targetModuleName": targetModule,
            "modules": modules,
            "output": output.path,
        ]
        manifest["packageDirectory"] = packageDirectory ?? workspace.path

        let manifestPath = workspace.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [])
            .write(to: manifestPath)

        let process = Process()
        process.executableURL = Self.executable
        process.arguments = [manifestPath.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        let diagnostics =
            String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        let generated = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        return Result(
            exitCode: process.terminationStatus, diagnostics: diagnostics, generated: generated)
    }

    // MARK: - The happy path

    @Test("a component is registered with its lifetime and stereotype")
    func registersComponent() throws {
        let result = try generate([
            "UserService.swift": """
            import AlulaCore
            @Service final class UserService: Sendable {
            init() {}
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("UserService"))
        #expect(result.generated.contains(#"typeName: "UserService", stereotype: "service""#))
    }

    @Test("the generated body is exactly this — indentation included")
    func generatedBodyIsGolden() throws {
        // Every other test here asks `contains`, which cannot see the shape of
        // what was emitted. That blind spot let a cleanup pass collapse the
        // indentation inside the generator's own string literals: the output
        // still compiled, still contained every expected substring, and every
        // test still passed, while every Alula app got a mangled generated
        // file. This asserts the whole body, so shape regressions fail here.
        let result = try generate([
            "Sources.swift": """
            import AlulaCore
            protocol Greeter {}
            @Service
            struct EnglishGreeter: Greeter {}
            @Component
            final class Welcomer {
                @Inject var greeter: (any Greeter)
            }
            """
        ])

        #expect(result.exitCode == 0)
        // The construction the whole migration turns on: `AlulaGraph`, which
        // builds every component once, in dependency order, without a
        // container. It is the last declaration this fixture emits (no routes,
        // no composer), and its body is what this test pins so a shape
        // regression in the graph fails here. The `@Inject var _: (any Greeter)`
        // resolves through the one scanned conformer — inlined as
        // `greeter: englishGreeter` rather than a runtime bridge.
        let marker = "struct AlulaGraph {"
        let start = try #require(result.generated.range(of: marker)).lowerBound
        let body = String(result.generated[start...])
            .trimmingCharacters(in: .newlines)
        #expect(
            body == """
                struct AlulaGraph {
                    let englishGreeter: EnglishGreeter
                    let welcomer: Welcomer

                    init(englishGreeter: EnglishGreeter? = nil, welcomer: Welcomer? = nil) throws {
                        let englishGreeter = englishGreeter ?? EnglishGreeter()
                        self.englishGreeter = englishGreeter
                        let welcomer = welcomer ?? Welcomer(greeter: englishGreeter)
                        self.welcomer = welcomer
                    }
                }
                """)
    }

    // MARK: - Module-registered types (registration gating)

    @Test("a `alula:module-registered` type is scanned but not registered")
    func moduleRegisteredTypeIsNotEmitted() throws {
        let result = try generate([
            "Sources.swift": """
            import AlulaCore
            @Component final class Ordinary: Sendable { init() {} }
            // alula:module-registered — its own module registers it.
            @Component final class Gated: Sendable { init() {} }
            """
        ])
        #expect(result.exitCode == 0)
        // Ordinary is a graph node — the graph builds it.
        #expect(result.generated.contains("let ordinary: Ordinary"))
        #expect(
            !result.generated.contains("let gated: Gated"),
            "a module-registered type is not a graph node — its own module builds it")
        // Named rather than silently dropped: the scanned manifest still
        // carries it, flagged, so "why is my type not built here" is
        // answerable by reading the generated file.
        #expect(result.generated.contains("Gated"))
        #expect(result.generated.contains("isModuleRegistered: true"))
    }

    /// The hazard the marker exists for, in miniature: composition builds every
    /// singleton eagerly, so building a type whose dependency only a module
    /// provides breaks any app that merely links the package. A bridge to it
    /// would assert the same thing, so it must not be generated either.
    @Test("a module-registered type is not used as an existential bridge conformer")
    func moduleRegisteredTypeIsNotBridged() throws {
        let result = try generate([
            "Sources.swift": """
            import AlulaCore
            protocol Validator {}
            // alula:module-registered
            @Service struct GatedValidator: Validator {}
            @Component final class Consumer {
                @Inject var validator: (any Validator)
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(
            !result.generated.contains("container.register((any Validator).self"),
            "bridging to a conditionally-present type reintroduces the freeze failure")
    }

    @Test("registration order is deterministic across runs")
    func deterministicOutput() throws {
        let sources = [
            "A.swift": "import AlulaCore\n@Component final class Alpha: Sendable { init() {} }",
            "B.swift": "import AlulaCore\n@Component final class Beta: Sendable { init() {} }",
            "C.swift": "import AlulaCore\n@Component final class Gamma: Sendable { init() {} }",
        ]
        let first = try generate(sources)
        let second = try generate(sources)
        #expect(first.exitCode == 0)
        #expect(first.generated == second.generated, "codegen must not depend on filesystem order")
    }

    @Test("a file with no Alula attributes contributes nothing")
    func ignoresUnrelatedSources() throws {
        let result = try generate([
            "Plain.swift": "struct NotAComponent { let value = 1 }"
        ])
        #expect(result.exitCode == 0)
        #expect(!result.generated.contains("NotAComponent"))
    }

    // MARK: - Required-key checks against alula.yaml
    //
    // A @ConfigValue with no default:, or a @Settings property with no
    // default value, must exist in alula.yaml's base layer — checked here
    // at build time rather than left to surface as a bootstrap-time throw.
    // No prior test drove this executable end to end; these do.

    @Test("a required @ConfigValue key missing from alula.yaml is a build error")
    func requiredConfigValueKeyMissingIsAnError() throws {
        let result = try generate(
            [
                "Server.swift": """
                import AlulaCore
                @Component final class ServerConfig: Sendable {
                    @ConfigValue("server.port") let port: Int
                }
                """
            ],
            alulaYAML: "other:\n  key: value\n"
        )
        #expect(result.exitCode != 0)
        #expect(result.diagnostics.contains("server.port"))
        #expect(result.diagnostics.contains("@ConfigValue"))
    }

    @Test("a throwing node initializer is spelled so the emitted file compiles")
    func throwingNodeInitializerIsMarkedCorrectly() throws {
        // `??` passes its right side as an autoclosure, so a throw escapes
        // through the operator: `x ?? (try C())` is rejected with "operator
        // can throw but expression is not marked with 'try'". The generated
        // file compiled in no test here — the harness asserts on text — so
        // this shape shipped broken. Asserting on the spelling is the cheap
        // half of that gap; it is what a real app's build would have caught.
        let result = try generate(
            [
                "Settings.swift": """
                import AlulaCore
                @Component struct Settings {
                    @ConfigValue("app.name") var appName: String
                }
                """
            ],
            alulaYAML: "app:\n  name: demo\n"
        )
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("try (settings ?? Settings("))
        #expect(
            !result.generated.contains("?? (try "),
            "the try must cover the whole coalescing, not just the call")
    }

    @Test("a custom prefix keeps the key check at build time")
    func customPrefixIsStillCheckedAtBuildTime() throws {
        // The prefix looks like a runtime value, but it is a literal in the
        // application's own source and that source is scanned — so renaming
        // the base layer does not cost the compile-time guarantee.
        let result = try generate(
            [
                "Main.swift": """
                import AlulaCore
                @Component struct Settings {
                    @ConfigValue("app.name") var appName: String
                }
                @main struct Main {
                    static func main() async {
                        await Alula.run(
                            configuration: try Configuration.load(prefix: "myapp"),
                            modules: [AppModule.self],
                            composedBy: alulaComposeModules)
                    }
                }
                """
            ],
            configFiles: ["myapp.yaml": "other:\n  key: value\n"]
        )
        #expect(result.exitCode != 0, "the missing key must fail the build")
        #expect(result.diagnostics.contains("app.name"))
        #expect(result.diagnostics.contains("myapp.yaml"))
    }

    @Test("a custom prefix whose key is present builds clean and silent")
    func customPrefixSatisfiedIsSilent() throws {
        let result = try generate(
            [
                "Main.swift": """
                import AlulaCore
                @Component struct Settings {
                    @ConfigValue("app.name") var appName: String
                }
                let configuration = try Configuration.load(prefix: "myapp")
                """
            ],
            configFiles: ["myapp.yaml": "app:\n  name: demo\n"]
        )
        #expect(result.exitCode == 0)
        #expect(result.diagnostics.isEmpty, "a satisfied check says nothing")
    }

    @Test("alula.yaml is not a fallback when a custom prefix is declared")
    func customPrefixDoesNotFallBackToTheDefault() throws {
        // Checking the wrong file would be worse than not checking: it would
        // report success about a file the application never loads.
        let result = try generate(
            [
                "Main.swift": """
                import AlulaCore
                @Component struct Settings {
                    @ConfigValue("app.name") var appName: String
                }
                let configuration = try Configuration.load(prefix: "myapp")
                """
            ],
            alulaYAML: "app:\n  name: from-the-wrong-file\n"
        )
        #expect(result.exitCode == 0, "a missing base file is not a build failure")
        #expect(result.diagnostics.contains("myapp.yaml"), "it must look for the declared file")
        #expect(result.diagnostics.contains("did not run"))
    }

    @Test("a literal that is not a legal prefix is a build error, not a startup trap")
    func illegalPrefixIsABuildError() throws {
        let result = try generate([
            "Main.swift": """
            import AlulaCore
            @Component struct Settings {
                @ConfigValue("app.name") var appName: String
            }
            let configuration = try Configuration.load(prefix: "my-app")
            """
        ])
        #expect(result.exitCode != 0)
        #expect(result.diagnostics.contains("my-app"))
        #expect(result.diagnostics.contains("MY-APP_SERVER_PORT"))
    }

    @Test("a computed prefix is not statically knowable, and says so")
    func computedPrefixWarns() throws {
        let result = try generate([
            "Main.swift": """
            import AlulaCore
            @Component struct Settings {
                @ConfigValue("app.name") var appName: String
            }
            let name = "myapp"
            let configuration = try Configuration.load(prefix: ConfigPrefix(name))
            """
        ])
        #expect(result.exitCode == 0, "unknowable is not a failure")
        #expect(result.diagnostics.contains("not a plain string literal"))
        #expect(result.diagnostics.contains("did not run"))
    }

    @Test("no alula.yaml plus unchecked keys warns instead of skipping in silence")
    func missingBaseFileWarnsAboutUncheckedKeys() throws {
        // A custom ConfigPrefix moves the base file out of a build tool's
        // reach, and so does simply forgetting the file. Either way the
        // compile-time guarantee is not being provided, and reporting success
        // is the one outcome that teaches people to trust a check that never
        // ran. A warning, not an error: the keys still fail at startup.
        let result = try generate([
            "Settings.swift": """
            import AlulaCore
            @Component struct Settings {
                @ConfigValue("app.name") var appName: String
            }
            """
        ])
        #expect(result.exitCode == 0, "a missing base file is not a build failure")
        #expect(result.diagnostics.contains("warning"))
        #expect(result.diagnostics.contains("app.name"))
        #expect(result.diagnostics.contains("did not run"))
    }

    @Test("a required @ConfigValue key present in alula.yaml succeeds")
    func requiredConfigValueKeyPresentSucceeds() throws {
        let result = try generate(
            [
                "Server.swift": """
                import AlulaCore
                @Component final class ServerConfig: Sendable {
                    @ConfigValue("server.port") let port: Int
                }
                """
            ],
            alulaYAML: "server:\n  port: 8080\n"
        )
        #expect(result.exitCode == 0)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("a required @Settings property missing from alula.yaml is a build error, without claiming @ConfigValue was written")
    func requiredSettingsKeyMissingIsAnError() throws {
        let result = try generate(
            [
                "AuthSettings.swift": """
                import AlulaCore
                @Settings("auth")
                struct AuthSettings: Sendable {
                    var signingKey: String
                }
                """
            ],
            alulaYAML: "other:\n  key: value\n"
        )
        #expect(result.exitCode != 0)
        #expect(result.diagnostics.contains("auth.signing-key"))
        // The property has no @ConfigValue attribute at all — the message
        // must not claim one, or it would send someone looking for a line
        // of code that was never written.
        #expect(!result.diagnostics.contains("@ConfigValue"))
    }

    @Test("a required @Settings property present in alula.yaml succeeds")
    func requiredSettingsKeyPresentSucceeds() throws {
        let result = try generate(
            [
                "AuthSettings.swift": """
                import AlulaCore
                @Settings("auth")
                struct AuthSettings: Sendable {
                    var signingKey: String
                }
                """
            ],
            alulaYAML: "auth:\n  signing-key: a-real-signing-key\n"
        )
        #expect(result.exitCode == 0)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("a @Settings property with its own default needs no alula.yaml entry at all")
    func optionalSettingsKeyNeedsNoEntry() throws {
        let result = try generate(
            [
                "AuthSettings.swift": """
                import AlulaCore
                @Settings("auth")
                struct AuthSettings: Sendable {
                    var issuer: String = "myapp"
                }
                """
            ]
            // No alulaYAML at all — packageDirectory still gets set (the
            // workspace itself), so this also proves a missing alula.yaml
            // file is "skip the check", not "every required-looking key
            // fails".
        )
        #expect(result.exitCode == 0)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("a @Settings property overridden with an explicit @ConfigValue key is checked under that key")
    func settingsExplicitKeyOverrideIsChecked() throws {
        let result = try generate(
            [
                "AuthSettings.swift": """
                import AlulaCore
                @Settings("auth")
                struct AuthSettings: Sendable {
                    @ConfigValue("legacy.audience") let audience: String
                }
                """
            ],
            alulaYAML: "auth:\n  audience: not-the-right-key\n"
        )
        #expect(result.exitCode != 0)
        #expect(result.diagnostics.contains("legacy.audience"))
        // The derived key must not also be checked — only the explicit one.
        #expect(!result.diagnostics.contains("auth.audience"))
    }

    // MARK: - Existential bridge synthesis
    //
    // The most intricate code in the generator, and — before these tests — the
    // part nothing had ever executed: the demo app that served as its only
    // validation happens to synthesize zero bridges.

    @Test("a protocol with exactly one conformer gets a synthesized bridge")
    func synthesizesBridgeForSoleConformer() throws {
        let result = try generate([
            "Repo.swift": """
            import AlulaCore
            protocol UserRepositoryProtocol: Sendable {}
            @Repository final class UserRepository: UserRepositoryProtocol, Sendable {
            init() {}
            }
            @Service final class UserService: Sendable {
            @Inject var repository: any UserRepositoryProtocol
            init() {}
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(
            result.generated.contains("UserRepositoryProtocol"),
            "a request for `any P` with a sole conformer should synthesize a bridge"
        )
        #expect(
            !result.diagnostics.contains("UserRepositoryProtocol"),
            "a synthesized bridge should satisfy the request without a diagnostic"
        )
    }

    @Test("a protocol with two conformers is not bridged, and says why")
    func ambiguousProtocolIsNotBridged() throws {
        let result = try generate([
            "Two.swift": """
            import AlulaCore
            protocol Greeter: Sendable {}
            @Component final class English: Greeter, Sendable { init() {} }
            @Component final class French: Greeter, Sendable { init() {} }
            """
        ])
        // Ambiguity must not silently resolve to whichever was scanned first.
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("English"))
        #expect(result.generated.contains("French"))
    }

    @Test("a conformance declared in an extension still counts")
    func extensionConformanceIsSeen() throws {
        let result = try generate([
            "Service.swift": """
            import AlulaCore
            protocol Pinger: Sendable {}
            @Component final class Pinger1: Sendable { init() {} }
            extension Pinger1: Pinger {}
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("Pinger1"))
    }

    // MARK: - Diagnostics

    @Test("a missing registration is reported")
    func reportsMissingRegistration() throws {
        let result = try generate([
            "Needy.swift": """
            import AlulaCore
            @Service final class Needy: Sendable {
            @Inject var missing: NoSuchComponent
            init() {}
            }
            """
        ])
        #expect(
            result.diagnostics.contains("NoSuchComponent"),
            "an unsatisfiable dependency must name the type it could not find"
        )
    }

    @Test("a dependency cycle is reported and names both types")
    func reportsCycle() throws {
        let result = try generate([
            "Cycle.swift": """
            import AlulaCore
            @Component final class Ping: Sendable {
            @Inject var pong: Pong
            init() {}
            }
            @Component final class Pong: Sendable {
            @Inject var ping: Ping
            init() {}
            }
            """
        ])
        #expect(result.diagnostics.lowercased().contains("cycl"))
        #expect(result.diagnostics.contains("Ping") && result.diagnostics.contains("Pong"))
    }

    @Test("a hand-registered marker suppresses the missing-registration report")
    func handRegisteredMarkerSuppresses() throws {
        let result = try generate([
            "Marked.swift": """
            import AlulaCore
            @Service final class Marked: Sendable {
            // alula:hand-registered
            @Inject var external: SomethingRegisteredByHand
            init() {}
            }
            """
        ])
        #expect(
            !result.diagnostics.contains("SomethingRegisteredByHand"),
            "the documented escape hatch must actually suppress the diagnostic"
        )
    }

    // MARK: - AlulaGraph

    @Test("the graph builds every component once, in dependency order")
    func graphIsTopologicallyOrdered() throws {
        let result = try generate([
            "Sources.swift": """
            import AlulaCore
            @Repository
            struct UserRepository: Sendable {}
            @Service
            struct UserService: Sendable {
            @Inject var repo: UserRepository
            }
            """
        ])
        #expect(result.exitCode == 0)
        let repo = try #require(result.generated.range(of: "self.userRepository ="))
        let service = try #require(result.generated.range(of: "self.userService ="))
        #expect(repo.lowerBound < service.lowerBound, "a dependency is built before its dependent")
        // Labelled by property name, which is what the generated initializer
        // uses — not by type name.
        #expect(result.generated.contains("UserService(repo: userRepository)"))
    }

    @Test("a dependency the graph cannot build becomes a root parameter")
    func unbuildableDependencyBecomesAParameter() throws {
        // §2.6's escape hatch: externally supplied values arrive through the
        // same typed parameters everything else uses, at one root rather than
        // scattered across many separate configuration sites. A value a module
        // provides that the graph itself cannot build is the ordinary case.
        let result = try generate([
            "Sources.swift": """
            import AlulaCore
            @Repository
            struct UserRepository: Sendable {
            @Inject var pool: PostgresDataSource
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("init(postgresDataSource: PostgresDataSource,"))
        #expect(result.generated.contains("UserRepository(pool: postgresDataSource)"))
    }

    @Test("an existential dependency resolves to its single conformer")
    func existentialResolvesToConformer() throws {
        // The same mapping the synthesized bridges use, so the graph and the
        // registration path agree about which concrete type answers `any P`.
        let result = try generate([
            "Sources.swift": """
            import AlulaCore
            protocol UserStore {}
            @Repository
            struct UserRepository: UserStore {}
            @Service
            struct UserService: Sendable {
            @Inject var store: (any UserStore)
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("UserService(store: userRepository)"))
    }

    @Test("a config-reading component takes the configuration and throws")
    func configurationIsARootParameter() throws {
        let result = try generate([
            "Sources.swift": """
            import AlulaCore
            @Service
            struct Pager: Sendable {
            @ConfigValue("app.page-size") var size: Int
            }
            """,
        ], alulaYAML: "app:\n  page-size: 25\n")
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("init(configuration: AlulaCore.Configuration,"))
        // `try (x ?? C())`, not `x ?? (try C())`. This assertion pinned the
        // latter — which never compiled, because `??` takes its right side as
        // an autoclosure and the throw escapes through the operator. It passed
        // anyway: nothing here compiles what the generator emits, so the shape
        // was wrong in every Alula app with a @ConfigValue component while
        // this test stayed green. Don't "restore" the old spelling.
        #expect(
            result.generated.contains("try (pager ?? Pager(_alulaConfiguration: configuration))"))
    }

    @Test("a module-registered component is left out of the graph")
    func moduleRegisteredIsExcluded() throws {
        // Same reason the composition root leaves it out: whether it exists in
        // an application is a runtime question its own module answers.
        let result = try generate([
            "Sources.swift": """
            import AlulaWeb
            // alula:module-registered
            @Middleware struct Authentication: Sendable {}
            @Service struct Other: Sendable {}
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("let other: Other"))
        #expect(!result.generated.contains("let authentication: Authentication"))
    }

    @Test("a hand-registered dependency becomes a required graph input, not a container resolve")
    func handRegisteredDependencyIsAGraphInput() throws {
        // A `alula:hand-registered` @Inject names something the scan does not
        // build — a root input the composition root supplies. The graph takes
        // it as a required init parameter (no `= nil` default) and builds the
        // component from it; there is no container to resolve it from.
        let result = try generate([
            "Sources.swift": """
            import AlulaCore
            @Repository
            struct UserRepository: Sendable {
            // alula:hand-registered
            @Inject var pool: PostgresDataSource
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("let postgresDataSource: PostgresDataSource"))
        #expect(result.generated.contains("init(postgresDataSource: PostgresDataSource"))
        #expect(result.generated.contains("UserRepository(pool: postgresDataSource)"))
    }

    @Test("routes are emitted with a per-request controller, through the macro's factory")
    func routesConstructPerRequest() throws {
        let result = try generate([
            "Sources.swift": """
            import AlulaWeb
            @Service
            struct UserService: Sendable {}
            @Controller("/users")
            struct UserController {
            @Inject var users: UserService
            @GetRoute("/:id")
            func show(_ context: RequestContext) -> String { "x" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        // The whole route lives in the factory the macro generated; this
        // supplies only how the controller is obtained.
        #expect(
            result.generated.contains(
                "UserController._alulaRoute_show_0 { _ in UserController(users: graph.userService) }"
            ))
        // Routes are a value the composition root passes to AlulaWebModule,
        // so the graph arrives as a parameter rather than being resolved.
        #expect(result.generated.contains("func alulaRoutes(_ graph: AlulaGraph)"))
    }

    @Test("a controller is not a graph node — it is built per request")
    func controllerIsNotAGraphNode() throws {
        // The point of §2.1a: process dependencies are held, the controller
        // is not. A controller something *else* injects stays a node,
        // because then the graph does have to build it.
        let result = try generate([
            "Sources.swift": """
            import AlulaWeb
            @Service
            struct UserService: Sendable {}
            @Controller("/users")
            struct UserController {
            @Inject var users: UserService
            @GetRoute("/:id")
            func show(_ context: RequestContext) -> String { "x" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("let userService: UserService"))
        #expect(!result.generated.contains("let userController: UserController"))
    }

    @Test("a root input only a controller needs is a terminal parameter, not a graph property")
    func controllerOnlyRootInputIsTerminalParameter() throws {
        // It used to be stored on the graph, and that was the cycle: a
        // controller injecting `ChannelBroadcaster` made the graph depend on
        // `AlulaChannelsModule`, which takes the channel list — so nothing
        // that builds channels from the graph could compose. A controller is
        // not a component; what only it needs belongs to its terminal.
        let result = try generate([
            "Sources.swift": """
            import AlulaWeb
            @Controller("/socket")
            struct SocketController {
            // alula:hand-registered
            @Inject var validator: (any TokenValidator)
            @GetRoute("/")
            func open(_ context: RequestContext) -> String { "x" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        // Not a graph property...
        #expect(!result.generated.contains("let tokenValidator: (any TokenValidator)"))
        // ...a parameter of the route list, named for the type: two properties
        // of one type are one root input, which is what makes them the *same*
        // value.
        #expect(
            result.generated.contains(
                "func alulaRoutes(_ graph: AlulaGraph, tokenValidator: (any TokenValidator))"))
        #expect(
            result.generated.contains("SocketController(validator: tokenValidator)"))
    }

    @Test("two spellings of one terminal-only root are one parameter")
    func terminalRootSpellingsCollapse() throws {
        // `(any TokenValidator)` and `any TokenValidator` are the same type.
        // Keyed on the text, the demo template's two controllers produced
        // `alulaRoutes(_:tokenValidator:tokenValidator:)`, which does not
        // compile — and nothing in this suite had two controllers spelling
        // one injection two ways.
        let result = try generate([
            "Sources.swift": """
            import AlulaWeb
            @Controller("/socket")
            struct SocketController {
            // alula:hand-registered
            @Inject var validator: any TokenValidator
            @GetRoute("/")
            func open(_ context: RequestContext) -> String { "x" }
            }
            @Controller("/session")
            struct SessionController {
            // alula:hand-registered
            @Inject var validator: (any TokenValidator)
            @PostRoute("/")
            func signIn(_ context: RequestContext) -> String { "y" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        let signature = try #require(
            result.generated.split(separator: "\n").first { $0.hasPrefix("func alulaRoutes(") })
        #expect(signature.components(separatedBy: "tokenValidator:").count == 2, "\(signature)")
        #expect(result.generated.contains("SocketController(validator: tokenValidator)"))
        #expect(result.generated.contains("SessionController(validator: tokenValidator)"))
    }

    @Test("the graph constructs; the container projects onto it")
    func graphProjectsRatherThanRebuilds() throws {
        // One construction, in one place. Both mechanisms building would
        // give an application two of every component — a route terminal
        // reaching one through the graph, a channel or a job reaching the
        // other through the container. Harmless for a stateless repository;
        // a silent split-brain for anything holding state.
        let result = try generate([
            "Sources.swift": """
            import AlulaWeb
            @Service
            struct UserService: Sendable {}
            @Controller("/users")
            struct UserController {
            @Inject var users: UserService
            @GetRoute("/:id")
            func show(_ context: RequestContext) -> String { "x" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        // The graph constructs; the container projects onto it.
        #expect(result.generated.contains("let userService = userService ?? UserService()"))
        #expect(
            result.generated.contains("graph.userService"),
            "the container registration must project, not construct a second copy")
        #expect(
            !result.generated.contains("try UserService._alulaRegister"),
            "a projected component must not also be constructed by its own thunk")
    }

    @Test("a test can replace one node and get the rest of the graph real")
    func nodesAreDefaultedParameters() throws {
        // §2.10's claim, made real: a `AlulaGraph` with a defaulted parameter
        // per node lets a test replace one component and get the rest of the
        // graph real, without hand-rebuilding the object graph.
        let result = try generate([
            "Sources.swift": """
            import AlulaCore
            protocol UserStore {}
            @Repository
            struct UserRepository: UserStore {}
            @Service
            struct UserService: Sendable {
            @Inject var store: (any UserStore)
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("userRepository: UserRepository? = nil"))
        #expect(result.generated.contains("userService: UserService? = nil"))
        // The local binding, not the parameter, is what downstream nodes see
        // — otherwise a supplied instance would be composed around a second
        // copy of itself.
        #expect(
            result.generated.contains(
                "let userRepository = userRepository ?? UserRepository()"))
        #expect(result.generated.contains("UserService(store: userRepository)"))
    }

    @Test("an application whose only component is a controller still emits the graph")
    func controllerOnlyAppEmitsTheGraph() throws {
        // The skeleton template's shape, and a bug it caught that a richer
        // application could not: with the controller excluded from the graph
        // there are no nodes, but `alulaRoutes` still takes a `AlulaGraph` —
        // so gating the graph's *emission* on "has nodes" would emit a route
        // list referencing a type that was never defined.
        let result = try generate([
            "Sources.swift": """
            import AlulaWeb
            @Controller
            struct HealthController {
            @GetRoute("/")
            func index(_ context: RequestContext) -> String { "ok" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        // The (empty) graph is emitted regardless...
        #expect(result.generated.contains("struct AlulaGraph {"))
        // ...so the route terminals can take it as `alulaRoutes`' parameter.
        #expect(result.generated.contains("func alulaRoutes(_ graph: AlulaGraph)"))
    }

    // MARK: - The composition root

    @Test("the composer builds every included module, dependencies first")
    func composerBuildsInOrder() throws {
        let result = try generate([
            "Main.swift": """
            import AlulaWeb
            struct PubSubModule: AlulaModule {
            }
            struct ChannelsModule: AlulaModule {
            static var dependencies: [any AlulaModule.Type] { [PubSubModule.self] }
            init(configuration: Configuration, pubsub: PubSubModule) throws {}
            }
            @main struct Main {
            static func main() async {
            await Alula.run(configuration: .load(), modules: [ChannelsModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("let pubSubModule = PubSubModule()"))
        // A module that declares what it needs is wired from what came before.
        #expect(
            result.generated.contains(
                "let channelsModule = try ChannelsModule(configuration: configuration, pubsub: pubSubModule)"
            ))
    }

    @Test("a module brought in by another's dependencies is imported, though the target never imports it")
    func composerImportsDependencyModules() throws {
        // `AlulaWebModule` lists `AlulaTelemetryModule`, which lives in a
        // Swift module no application imports. The composer constructs it,
        // so the generated file must import it: it did not, and the first
        // application to include such a module failed to build.
        let result = try generate(
            [
                "Main.swift": """
                import AlulaCore
                import Stack
                @main struct Main {
                static func main() async {
                await Alula.run(configuration: Configuration.load(), modules: [StackModule.self])
                }
                }
                """
            ],
            dependencyModules: [
                "Stack": [
                    "StackModule.swift": """
                    import AlulaCore
                    import Reporting
                    public struct StackModule: AlulaModule {
                    public static var dependencies: [any AlulaModule.Type] { [ReportingModule.self] }
                    public init() {}
                    }
                    """
                ],
                "Reporting": [
                    "ReportingModule.swift": """
                    import AlulaCore
                    public struct ReportingModule: AlulaModule {
                    public init() {}
                    }
                    """
                ],
            ])
        #expect(result.exitCode == 0, "\(result.diagnostics)")
        #expect(result.generated.contains("let reportingModule = ReportingModule()"))
        #expect(result.generated.contains("import Reporting\n"))
        #expect(result.generated.components(separatedBy: "import Stack\n").count == 2, "once")
    }

    @Test("a module's property is wired into another module's parameter")
    func composerWiresProvidedProperties() throws {
        // The adapter shape: the provider declares no dependency on the
        // consumer and the consumer cannot name the provider — alula does not
        // know alula-data exists. The type is the whole connection.
        let result = try generate([
            "Main.swift": """
            import AlulaWeb
            struct ValkeyModule: AlulaModule {
            let adapter: any DistributedPubSubAdapter
            init(configuration: Configuration) throws {}
            }
            struct PubSubModule: AlulaModule {
            init(configuration: Configuration, adapter: (any DistributedPubSubAdapter)? = nil) throws {}
            }
            @main struct Main {
            static func main() async {
            await Alula.run(
            configuration: .load(), modules: [PubSubModule.self, ValkeyModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(
            result.generated.contains(
                "let pubSubModule = try PubSubModule(configuration: configuration, adapter: valkeyModule.adapter)"
            ))
        // And the provider is built first, though nothing declared that edge:
        // the application listed PubSub first, and neither module names the
        // other in `dependencies`.
        let valkey = try #require(result.generated.range(of: "let valkeyModule ="))
        let pubsub = try #require(result.generated.range(of: "let pubSubModule ="))
        #expect(valkey.lowerBound < pubsub.lowerBound)
    }

    @Test("an array parameter collects from every contributing module, in order")
    func composerConcatenatesAggregates() throws {
        // The extension seam: two modules contribute channels, neither knows
        // about the other, and the aggregator takes all of them. Several
        // providers of one type is the *right* answer here, which is why an
        // aggregate is not treated as the ambiguity a scalar would be.
        let result = try generate([
            "Main.swift": """
            import AlulaWeb
            struct ChatModule: AlulaModule {
            let channels: [ChannelRegistration]
            }
            struct NotificationsModule: AlulaModule {
            let channels: [ChannelRegistration]
            }
            struct AlulaChannelsModule: AlulaModule {
            init(channels: [ChannelRegistration] = []) throws {}
            }
            @main struct Main {
            static func main() async {
            await Alula.run(
            configuration: .load(),
            modules: [AlulaChannelsModule.self, ChatModule.self, NotificationsModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(
            result.generated.contains(
                "let alulaChannelsModule = try AlulaChannelsModule(channels: chatModule.channels + notificationsModule.channels)"
            ))
        // Both contributors are built before the aggregator, though the
        // application listed the aggregator first.
        let chat = try #require(result.generated.range(of: "let chatModule ="))
        let channels = try #require(result.generated.range(of: "let alulaChannelsModule ="))
        #expect(chat.lowerBound < channels.lowerBound)
    }

    @Test("an aggregate nobody contributes to is omitted")
    func composerOmitsEmptyAggregates() throws {
        // The ordinary app with no channels at all. `[]` is the default, so
        // the parameter is simply not passed.
        let result = try generate([
            "Main.swift": """
            import AlulaWeb
            struct AlulaChannelsModule: AlulaModule {
            init(channels: [ChannelRegistration] = []) throws {}
            }
            @main struct Main {
            static func main() async {
            await Alula.run(configuration: .load(), modules: [AlulaChannelsModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("let alulaChannelsModule = try AlulaChannelsModule()"))
    }

    @Test("the composition root builds the graph from what modules provide")
    func composerBuildsTheGraph() throws {
        let result = try generate([
            "Main.swift": """
            import AlulaWeb
            struct PoolModule: AlulaModule {
            let dataSource: DataSource
            init() { self.dataSource = DataSource() }
            }
            struct AppModule: AlulaModule {
            let graph: AlulaGraph
            init(graph: AlulaGraph) { self.graph = graph }
            }
            @Repository struct UserRepository { @Inject var pool: DataSource }
            @main struct Main {
            static func main() async {
            await Alula.run(
            configuration: .load(), modules: [AppModule.self, PoolModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        // The graph's root is a module's property, matched by type — the same
        // rule a module's own initializer parameters go through.
        #expect(
            result.generated.contains(
                "let alulaGraph = try AlulaGraph(dataSource: poolModule.dataSource)"))
        // And it sorts between them: after the module providing its root,
        // before the module that registers from it.
        let pool = try #require(result.generated.range(of: "let poolModule ="))
        let graph = try #require(result.generated.range(of: "let alulaGraph ="))
        let app = try #require(result.generated.range(of: "let appModule ="))
        #expect(pool.lowerBound < graph.lowerBound)
        #expect(graph.lowerBound < app.lowerBound)
        // The graph is a value, not a module: it is not in the returned list.
        let returned = try #require(result.generated.range(of: "return ["))
        #expect(!result.generated[returned.lowerBound...].contains("alulaGraph,"))
    }

    @Test("an injection a module provides is not reported as unscanned")
    func moduleProvidedInjectionIsNotReported() throws {
        // Relay's first build printed 25 of these, all about types — the data
        // source, the mailer, the job queue — the composer had wired.
        let result = try generate([
            "Main.swift": """
            import AlulaCore
            struct DataSource: Sendable {}
            struct PoolModule: AlulaModule {
            let dataSource: DataSource
            init() { self.dataSource = DataSource() }
            }
            struct AppModule: AlulaModule {
            let graph: AlulaGraph
            init(graph: AlulaGraph) { self.graph = graph }
            }
            @Repository struct UserRepository { @Inject var pool: DataSource }
            @main struct Main {
            static func main() async {
            await Alula.run(
            configuration: .load(), modules: [AppModule.self, PoolModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(!result.diagnostics.contains("not a scanned"), "\(result.diagnostics)")
    }

    @Test("a library target still reports an unscanned injection")
    func libraryTargetReportsUnscannedInjection() throws {
        // No `modules:` list: nothing here says who will provide it.
        let result = try generate([
            "Library.swift": """
            import AlulaCore
            @Repository struct UserRepository { @Inject var pool: DataSource }
            """
        ])
        #expect(result.diagnostics.contains("[ALU-DI-1009] `UserRepository` injects `DataSource`, which is not a scanned @Component"))
    }

    @Test("a graph root nothing provides is a build error naming the type")
    func composerReportsMissingGraphRoot() throws {
        let result = try generate([
            "Main.swift": """
            import AlulaWeb
            struct AppModule: AlulaModule {
            let graph: AlulaGraph
            init(graph: AlulaGraph) { self.graph = graph }
            }
            @Repository struct UserRepository { @Inject var pool: DataSource }
            @main struct Main {
            static func main() async {
            await Alula.run(configuration: .load(), modules: [AppModule.self])
            }
            }
            """
        ])
        // Reported against the source, and the build stops: nothing is
        // generated for a graph that cannot be wired (relay ISSUES #32).
        #expect(result.exitCode != 0)
        #expect(result.diagnostics.contains("[ALU-DI-1001] no module in this application provides `DataSource`"))
        #expect(!result.generated.contains("#error("))
    }

    @Test("a contribution nothing collects is a build error naming the module to add")
    func composerRefusesUnconsumedContributions() throws {
        // The footgun the aggregate rule would otherwise introduce: declaring
        // channels while leaving Channels out of the application composes
        // fine, starts fine, and finds no route at the first join. Exactly the
        // silence the PubSub inversion existed to remove.
        let result = try generate([
            "Main.swift": """
            import AlulaWeb
            struct AlulaChannelsModule: AlulaModule {
            init(channels: [ChannelRegistration] = []) throws {}
            }
            struct ChatModule: AlulaModule {
            let channels: [ChannelRegistration] = []
            }
            @main struct Main {
            static func main() async {
            await Alula.run(configuration: .load(), modules: [ChatModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode != 0)
        #expect(result.diagnostics.contains("[ALU-LIFE-8003] `ChatModule.channels` is contributed, but nothing"))
        // Names what to add, rather than only observing that it went unused.
        #expect(result.diagnostics.contains("add AlulaChannelsModule to `modules:`"))
    }

    @Test("a collected contribution is not reported")
    func composerAcceptsConsumedContributions() throws {
        let result = try generate([
            "Main.swift": """
            import AlulaWeb
            struct AlulaChannelsModule: AlulaModule {
            init(channels: [ChannelRegistration] = []) throws {}
            }
            struct ChatModule: AlulaModule {
            let channels: [ChannelRegistration] = []
            }
            @main struct Main {
            static func main() async {
            await Alula.run(
            configuration: .load(), modules: [ChatModule.self, AlulaChannelsModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(!result.generated.contains("#error("))
    }

    @Test("a dictionary parameter is not an aggregate")
    func composerDoesNotAggregateDictionaries() throws {
        // `[String: String]` is one value, and ActuatorModule's `environment`
        // is exactly that shape.
        let result = try generate([
            "Main.swift": """
            import AlulaWeb
            struct EnvModule: AlulaModule {
            let environment: [String: String]
            }
            struct ConsumerModule: AlulaModule {
            init(environment: [String: String]) {}
            }
            @main struct Main {
            static func main() async {
            await Alula.run(
            configuration: .load(), modules: [EnvModule.self, ConsumerModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(
            result.generated.contains(
                "let consumerModule = ConsumerModule(environment: envModule.environment)"))
    }

    @Test("dependencies are passed in declaration order, not injected-then-acknowledged")
    func graphPassesDependenciesInDeclarationOrder() throws {
        // The generated initializer takes its parameters in declaration order.
        // Emitting the injected ones first mislabels every call where a
        // `alula:hand-registered` property is declared before an injected
        // one — which reads as "argument 'validator' must precede argument
        // 'sockets'". Caught by the demo's SocketController, not by these.
        let result = try generate([
            "Main.swift": """
            import AlulaWeb
            @Service struct Sockets { init() {} }
            @Controller
            struct SocketController {
            // alula:hand-registered
            @Inject var validator: any TokenValidator
            @Inject var sockets: Sockets
            @GetRoute("/s")
            func show(_ context: RequestContext) -> String { "x" }
            }
            @main struct Main {
            static func main() async {
            await Alula.run(configuration: .load(), modules: [AppModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(
            result.generated.contains(
                "SocketController(validator: tokenValidator, sockets: graph.sockets)"))
    }

    @Test("a module is never built out of its own property")
    func composerExcludesSelfAsProvider() throws {
        // ActuatorModule's real shape: a stored `environment` and an
        // `init(environment:)` test seam. Matching providers by type made that
        // initializer look satisfiable by the module's own property, and the
        // composer emitted
        // `let actuatorModule = ActuatorModule(environment: actuatorModule.environment)`.
        // Caught by the demo template, not by these fixtures.
        let result = try generate([
            "Main.swift": """
            import AlulaWeb
            struct ActuatorModule: AlulaModule {
            let environment: [String: String]
            init() { self.environment = [:] }
            init(environment: [String: String]) { self.environment = environment }
            }
            @main struct Main {
            static func main() async {
            await Alula.run(configuration: .load(), modules: [ActuatorModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("let actuatorModule = ActuatorModule()"))
        #expect(!result.generated.contains("actuatorModule.environment"))
    }

    @Test("an optional parameter nothing provides is omitted, not failed")
    func composerOmitsUnprovidedOptionals() throws {
        // The single-node deployment: same PubSub module, no adapter module.
        // "Not in this deployment" has to compose, because it is the 90% case.
        let result = try generate([
            "Main.swift": """
            import AlulaWeb
            struct PubSubModule: AlulaModule {
            init(configuration: Configuration, adapter: (any DistributedPubSubAdapter)? = nil) throws {}
            }
            @main struct Main {
            static func main() async {
            await Alula.run(configuration: .load(), modules: [PubSubModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(
            result.generated.contains("let pubSubModule = try PubSubModule(configuration: configuration)"))
    }

    @Test("an optional parameter with no default and no provider is passed nil, not omitted")
    func composerPassesNilForRequiredOptionals() throws {
        // AlulaSecurityModule's shape: the validator is optional, but has no
        // default, so the call does not compile without it.
        let result = try generate([
            "Main.swift": """
            import AlulaWeb
            struct SecurityModule: AlulaModule {
            init(validator: (any TokenValidator)?, sessions: SessionRuntime? = nil) {}
            }
            @main struct Main {
            static func main() async {
            await Alula.run(configuration: .load(), modules: [SecurityModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("let securityModule = SecurityModule(validator: nil)"))
    }

    @Test("two modules providing the same type is a build error naming both")
    func composerRefusesAmbiguousProviders() throws {
        let result = try generate([
            "Main.swift": """
            import AlulaWeb
            struct ValkeyModule: AlulaModule {
            let adapter: any DistributedPubSubAdapter
            init(configuration: Configuration) throws {}
            }
            struct NatsModule: AlulaModule {
            let adapter: any DistributedPubSubAdapter
            init(configuration: Configuration) throws {}
            }
            struct PubSubModule: AlulaModule {
            init(configuration: Configuration, adapter: (any DistributedPubSubAdapter)? = nil) throws {}
            }
            @main struct Main {
            static func main() async {
            await Alula.run(
            configuration: .load(),
            modules: [PubSubModule.self, ValkeyModule.self, NatsModule.self])
            }
            }
            """
        ])
        // Reported against the source, failing the build. Silently picking
        // one would give a cluster wired to the wrong transport.
        #expect(result.exitCode != 0)
        #expect(result.diagnostics.contains("[ALU-DI-1002] 2 modules provide"))
        // Named as `Module.property`, not by the binding this generator
        // invented — `natsModule.adapter` is an identifier the reader has
        // never seen and cannot search for — each as a note at the property.
        #expect(result.diagnostics.contains("note: `NatsModule.adapter` provides"))
        #expect(result.diagnostics.contains("note: `ValkeyModule.adapter` provides"))
        // And it carries the remedy, which is the point of the message.
        #expect(result.diagnostics.contains("defaultProviders"))
    }

    @Test("a module's computed service is not something another module can take")
    func composerIgnoresComputedProperties() throws {
        // `var service: (any Service)?` is bootstrap's to collect. Treating it
        // as a provided value would let one module take another's service and
        // run it twice.
        let result = try generate([
            "Main.swift": """
            import AlulaWeb
            struct ProviderModule: AlulaModule {
            var service: (any Service)? { nil }
            }
            struct ConsumerModule: AlulaModule {
            init(service: (any Service)? = nil) {}
            }
            @main struct Main {
            static func main() async {
            await Alula.run(
            configuration: .load(), modules: [ProviderModule.self, ConsumerModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("let consumerModule = ConsumerModule()"))
    }

    @Test("a generic module keeps its type argument")
    func genericModuleKeepsItsArgument() throws {
        // `AlulaWebModule<AlulaTransport>` is one module named with the
        // transport it was chosen with. The argument is part of the module's
        // identity — matching and the binding name both carry it, because two
        // instantiations are two modules (D27).
        let result = try generate([
            "Main.swift": """
            import AlulaWeb
            final class AlulaWebModule<T: Sendable>: AlulaModule {
            }
            @main struct Main {
            static func main() async {
            await Alula.run(
            configuration: .load(), modules: [AlulaWebModule<AlulaTransport>.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(
            result.generated.contains(
                "let alulaWebModuleAlulaTransport = AlulaWebModule<AlulaTransport>()"))
    }

    @Test("a module property with no written type is warned about, not silently dropped")
    func untypedModulePropertyIsWarned() throws {
        // `AlulaSchedulerModule` shipped as `public let status = SchedulerStatus()`.
        // Matching needs the type as written, so the module provided
        // `SchedulerStatus` in fact and not in the composer's view, and
        // `@Inject var scheduler: SchedulerStatus` — which Actuator's own
        // documentation shows — could not be satisfied by any application.
        // Nothing said anything, which is the part worth fixing.
        let result = try generate([
            "Main.swift": """
            import AlulaCore
            struct Helper: Sendable {}
            struct AppModule: AlulaModule {
            let helper = Helper()
            private let hidden = Helper()
            init() {}
            }
            @main struct Main {
            static func main() async {
            await Alula.run(
            configuration: .load(), modules: [AppModule.self],
            composedBy: alulaComposeModules)
            }
            }
            """
        ])
        // A warning, not an error: the module may genuinely not mean to
        // provide it, and a build that refused would be worse than one that
        // says so.
        #expect(result.exitCode == 0)
        #expect(result.diagnostics.contains("[ALU-DI-1011]"))
        #expect(result.diagnostics.contains("helper` has no written type"))
        // `private` is how you say "not provided", so it must stay quiet.
        #expect(!result.diagnostics.contains("hidden"))
    }

    @Test("a @Settings type a component injects is built by the graph")
    func settingsComposeAsGraphNodes() throws {
        // `@Settings` was excluded from the graph, so a settings type arrived
        // as a *root* — and roots are resolved from what modules provide.
        // Nothing provides a settings type, so every application with one
        // failed with "no module in this application provides AppSettings"
        // about a type the generator had scanned itself.
        //
        // Nothing caught it: no template declares `@Settings`, the tests above
        // cover only its config-key check, and SettingsIntegrationTests builds
        // one directly rather than through the composer. The seam beside the
        // seam.
        let result = try generate(
            [
                "Main.swift": """
                import AlulaCore
                @Settings("app")
                struct AppSettings {
                var pageSize: Int = 50
                }
                @Service struct Reporter: Sendable {
                @Inject var settings: AppSettings
                }
                struct AppModule: AlulaModule {
                init() {}
                }
                @main struct Main {
                static func main() async {
                await Alula.run(
                configuration: .load(), modules: [AppModule.self],
                composedBy: alulaComposeModules)
                }
                }
                """
            ])
        #expect(result.exitCode == 0)
        // Built by the graph, through its own initializer — which is what runs
        // the `validate()` the exclusion was protecting.
        #expect(result.generated.contains("AppSettings(_alulaConfiguration: configuration)"))
        // And with `try`: that initializer throws whether or not any field was
        // recorded as a config value.
        #expect(result.generated.contains("try (appSettings ?? AppSettings("))
        #expect(!result.generated.contains("no module in this application provides"))
    }

    @Test("defaultProviders answers the unqualified inject, from: answers the other")
    func defaultProviderAndNamedProvider() throws {
        let result = try generate([
            "Main.swift": """
            import AlulaCore
            enum Primary: Sendable {}
            enum Analytics: Sendable {}
            struct Pool: Sendable {}
            struct PoolModule<Name: Sendable>: AlulaModule {
            let pool: Pool
            init() { pool = Pool() }
            }
            @Service struct Reporter: Sendable {
            // alula:hand-registered — PoolModule provides it.
            @Inject var primary: Pool
            // alula:hand-registered — PoolModule<Analytics> provides it.
            @Inject(from: PoolModule<Analytics>.self) var analytics: Pool
            }
            struct AppModule: AlulaModule {
            static var dependencies: [any AlulaModule.Type] {
            [PoolModule<Primary>.self, PoolModule<Analytics>.self]
            }
            static var defaultProviders: [any AlulaModule.Type] { [PoolModule<Primary>.self] }
            init() {}
            }
            @main struct Main {
            static func main() async {
            await Alula.run(
            configuration: .load(), modules: [AppModule.self],
            composedBy: alulaComposeModules)
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        // Two roots, not one shared: the second is keyed by the provider it
        // named, or both properties would read the same pool.
        #expect(result.generated.contains("let pool: Pool"))
        #expect(result.generated.contains("let poolAnalytics: Pool"))
        #expect(
            result.generated.contains(
                "AlulaGraph(pool: poolModulePrimary.pool, poolAnalytics: poolModuleAnalytics.pool)"
            ))
        #expect(result.generated.contains("Reporter(primary: pool, analytics: poolAnalytics)"))
    }

    @Test("two providers and no default is an error that shows how to fix it")
    func ambiguityCarriesItsRemedy() throws {
        let result = try generate([
            "Main.swift": """
            import AlulaCore
            enum Primary: Sendable {}
            enum Analytics: Sendable {}
            struct Pool: Sendable {}
            struct PoolModule<Name: Sendable>: AlulaModule {
            let pool: Pool
            init() { pool = Pool() }
            }
            @Service struct Reporter: Sendable {
            // alula:hand-registered — PoolModule provides it.
            @Inject var primary: Pool
            }
            struct AppModule: AlulaModule {
            static var dependencies: [any AlulaModule.Type] {
            [PoolModule<Primary>.self, PoolModule<Analytics>.self]
            }
            init() {}
            }
            @main struct Main {
            static func main() async {
            await Alula.run(
            configuration: .load(), modules: [AppModule.self],
            composedBy: alulaComposeModules)
            }
            }
            """
        ])
        // Reported against the source, and the build stops there.
        #expect(result.exitCode != 0)
        #expect(result.diagnostics.contains("[ALU-DI-1002]"))
        // The remedy, not just the complaint — this is the moment an
        // application acquires a second provider and the build is the only
        // thing that knows.
        #expect(result.diagnostics.contains("defaultProviders"))
        #expect(result.diagnostics.contains("@Inject(from:"))
        // And not the contradiction it used to print alongside: `provider`
        // returns nil for ambiguity as well as absence, and claiming nothing
        // provides Pool while two modules do sent people hunting for a module
        // to add.
        #expect(!result.diagnostics.contains("[ALU-DI-1001]"))
        // No editor placeholder either: `<#…#>` is itself a compile error, so
        // it buried the message above under "editor placeholder in source file".
        #expect(!result.generated.contains("<#"))
    }

    @Test("defaultProviders also settles a module initializer parameter")
    func defaultProviderSettlesInitParameter() throws {
        // The @Inject case is covered above. A module's *initializer* is the
        // other side of the same matching rule, and it is the one the docs
        // lead with — `init(clock: Clock)` satisfied by whichever module
        // provides a `Clock`. It resolves through the same `provider(of:for:)`,
        // so a nomination has to settle it too; nothing pinned that it did.
        //
        // The asymmetry this also documents: an init parameter has no
        // `from:` to write, so the default is all it can get.
        let result = try generate([
            "Main.swift": """
            import AlulaCore
            enum System: Sendable {}
            enum Fixed: Sendable {}
            struct Clock: Sendable {}
            struct ClockModule<Kind: Sendable>: AlulaModule {
            let clock: Clock
            init() { clock = Clock() }
            }
            struct GreetingModule: AlulaModule {
            static var dependencies: [any AlulaModule.Type] {
            [ClockModule<System>.self, ClockModule<Fixed>.self]
            }
            static var defaultProviders: [any AlulaModule.Type] { [ClockModule<System>.self] }
            let greeting: String
            init(clock: Clock) { greeting = "hello" }
            }
            @main struct Main {
            static func main() async {
            await Alula.run(
            configuration: .load(), modules: [GreetingModule.self],
            composedBy: alulaComposeModules)
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        // The nominated module's property, not the other one and not a
        // stalled composition.
        #expect(result.generated.contains("GreetingModule(clock: clockModuleSystem.clock)"))
        #expect(!result.diagnostics.contains("[ALU-DI-1002]"))
    }

    @Test("from: naming a module the application does not include is an error")
    func namedProviderMustBeInTheApplication() throws {
        let result = try generate([
            "Main.swift": """
            import AlulaCore
            enum Primary: Sendable {}
            enum Analytics: Sendable {}
            struct Pool: Sendable {}
            struct PoolModule<Name: Sendable>: AlulaModule {
            let pool: Pool
            init() { pool = Pool() }
            }
            @Service struct Reporter: Sendable {
            // alula:hand-registered — PoolModule provides it.
            @Inject(from: PoolModule<Analytics>.self) var analytics: Pool
            }
            struct AppModule: AlulaModule {
            static var dependencies: [any AlulaModule.Type] { [PoolModule<Primary>.self] }
            init() {}
            }
            @main struct Main {
            static func main() async {
            await Alula.run(
            configuration: .load(), modules: [AppModule.self],
            composedBy: alulaComposeModules)
            }
            }
            """
        ])
        #expect(result.exitCode != 0)
        #expect(result.diagnostics.contains("[ALU-DI-1006]"))
        #expect(result.diagnostics.contains("does not include"))
    }

    @Test("two instantiations of one generic module get two bindings")
    func twoInstantiationsGetTwoBindings() throws {
        // The shape alula-data is built on — `PostgresDataModule<Name>` once
        // per datasource — and documented from the start. It never worked:
        // module identity discarded the generic argument, so both collapsed to
        // one key, `resolveIncludedModules` visited only the first, and a
        // module taking both received the same binding twice:
        //
        //     let poolModule = PoolModule<Primary>()
        //     let appModule = AppModule(primary: poolModule, analytics: poolModule)
        //
        // which fails to compile with "cannot convert 'PoolModule<Primary>' to
        // 'PoolModule<Analytics>'" — in generated code, naming neither the
        // application's file nor its mistake. Nothing caught it because the
        // test above covers one instantiation and nothing covered two.
        let result = try generate([
            "Main.swift": """
            import AlulaCore
            enum Primary: Sendable {}
            enum Analytics: Sendable {}
            struct Pool: Sendable {}
            struct PoolModule<Name: Sendable>: AlulaModule {
            let pool: Pool
            init() { pool = Pool() }
            }
            struct AppModule: AlulaModule {
            static var dependencies: [any AlulaModule.Type] {
            [PoolModule<Primary>.self, PoolModule<Analytics>.self]
            }
            init(primary: PoolModule<Primary>, analytics: PoolModule<Analytics>) {}
            }
            @main struct Main {
            static func main() async {
            await Alula.run(
            configuration: .load(), modules: [AppModule.self],
            composedBy: alulaComposeModules)
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("let poolModulePrimary = PoolModule<Primary>()"))
        #expect(result.generated.contains("let poolModuleAnalytics = PoolModule<Analytics>()"))
        // The point: each parameter gets *its own* binding.
        #expect(
            result.generated.contains(
                "AppModule(primary: poolModulePrimary, analytics: poolModuleAnalytics)"))
    }

    @Test("a module declaring init() is constructed that way, whatever else it offers")
    func noArgumentInitWins() throws {
        // ActuatorModule declares init() *and* init(processEnvironment:) —
        // the second is a test seam, and picking the first parameterized
        // initializer found chose the seam.
        let result = try generate([
            "Main.swift": """
            import AlulaWeb
            struct ActuatorModule: AlulaModule {
            init() {}
            init(processEnvironment: [String: String]) {}
            }
            @main struct Main {
            static func main() async {
            await Alula.run(configuration: .load(), modules: [ActuatorModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("let actuatorModule = ActuatorModule()"))
        #expect(!result.generated.contains("processEnvironment:"))
    }

    @Test("an all-defaulted initializer does not outrank one the composer can feed")
    func suppliedArgumentsDecide() throws {
        // Once defaults are omittable, `init(verbose:retries:limit:)` is
        // satisfiable with nothing, and ranking by declared parameters would
        // pick it over `init(configuration:)` — silently ignoring configuration.
        let result = try generate([
            "Main.swift": """
            import AlulaWeb
            struct ThingModule: AlulaModule {
            init(configuration: Configuration) throws {}
            init(verbose: Bool = false, retries: Int = 3, limit: Int = 10) {}
            }
            @main struct Main {
            static func main() async {
            await Alula.run(configuration: .load(), modules: [ThingModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("let thingModule = try ThingModule(configuration: configuration)"))
    }

    @Test("a parameter with a default is omitted, not a reason to discard the initializer")
    func defaultedParameterIsOmitted() throws {
        // ActuatorModule's real shape since 0.23.0. The defaulted `logger:`
        // made its composition initializer unsatisfiable, every application
        // fell back to `init()`, and Actuator ran with a private health
        // registry — readiness always up — and an open dashboard whatever
        // `actuator.dashboard-roles` said. Nothing failed.
        let result = try generate([
            "Main.swift": """
            import AlulaWeb
            struct Logger { init(label: String) {} }
            struct ActuatorModule: AlulaModule {
            init() {}
            init(processEnvironment: [String: String]) {}
            init(configuration: Configuration, health: ModuleHealthRegistry = ModuleHealthRegistry(), logger: Logger = Logger(label: "x")) throws {}
            }
            @main struct Main {
            static func main() async {
            await Alula.run(configuration: .load(), modules: [ActuatorModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(
            result.generated.contains(
                "let actuatorModule = try ActuatorModule(configuration: configuration, health: alulaHealth)"))
    }

    // MARK: - Included modules

    @Test("the bootstrap list resolves transitively, dependencies first")
    func includedModulesResolve() throws {
        // The fact D11 turns on: which subsystems an application includes is
        // a literal in its own source, so it is knowable at build time. It
        // was treated as a runtime question only because the container was
        // the one thing that knew it.
        let result = try generate([
            "Main.swift": """
            import AlulaWeb
            struct AppModule: AlulaModule {
            static var dependencies: [any AlulaModule.Type] { [ChannelsModule.self] }
            }
            struct ChannelsModule: AlulaModule {
            static var dependencies: [any AlulaModule.Type] { [PubSubModule.self] }
            }
            struct PubSubModule: AlulaModule {
            }
            struct UnlistedModule: AlulaModule {
            }
            @main struct Main {
            static func main() async {
            await Alula.run(configuration: .load(), modules: [AppModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(
            result.generated.contains(
                #""PubSubModule",\n        "ChannelsModule",\n        "AppModule","#
                    .replacingOccurrences(of: "\\n", with: "\n")),
            "dependencies come before the module that pulled them in")
        // Linked but never listed: present in the graph, absent from the set.
        #expect(result.generated.contains(#"name: "UnlistedModule""#))
        let start = try #require(
            result.generated.range(of: "public static let includedModules")).lowerBound
        let end = try #require(result.generated.range(of: "\n    ]", range: start..<result.generated.endIndex)).upperBound
        #expect(!result.generated[start..<end].contains("UnlistedModule"))
    }

    @Test("a target that starts nothing includes nothing")
    func libraryIncludesNothing() throws {
        let result = try generate([
            "Sources.swift": """
            import AlulaCore
            @Service struct UserService: Sendable {}
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("public static let includedModules: [String] = [\n    ]"))
    }

    // MARK: - Undeclared lanes

    @Test("a route naming an undeclared lane is warned about at build time")
    func undeclaredLaneWarns() throws {
        let result = try generate([
            "AppModule.swift": """
            import AlulaWeb
            @Controller("/admin", pipelines: ["audit"])
            struct AdminController {
            @GetRoute("/")
            func index(_ context: RequestContext) -> String { "x" }
            }
            """
        ])
        // A warning, not an error: the scan reaches source dependencies only,
        // so a lane declared in a binary dependency is invisible to it.
        // UndeclaredLaneError at bootstrap stays the enforcement.
        #expect(result.exitCode == 0)
        #expect(result.diagnostics.contains("warning"))
        #expect(result.diagnostics.contains("audit"))
    }

    @Test("a declared lane is not warned about")
    func declaredLaneIsQuiet() throws {
        let result = try generate([
            "AppModule.swift": """
            import AlulaWeb
            struct AppModule: AlulaModule {
            let middleware = MiddlewareRegistration.lane("audit", [AuditLog()])
            }
            @Controller("/admin", pipelines: ["audit"])
            struct AdminController {
            @GetRoute("/")
            func index(_ context: RequestContext) -> String { "x" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(!result.diagnostics.contains("audit"))
    }

    @Test("a lane declared with a computed list is still declared")
    func laneWithComputedListIsDeclared() throws {
        // AlulaSecurityModule's shape: the list is `session + [...]`, not a
        // literal. Its middleware cannot be read; its lane name can, and every
        // route on `.authenticated` depends on the scan seeing it.
        let result = try generate(
            [
                "AppModule.swift": """
                import AlulaWeb
                @Controller("/me", pipelines: [.authenticated])
                struct MeController {
                @GetRoute("/")
                func index(_ context: RequestContext) -> String { "x" }
                }
                """
            ],
            dependencyModules: [
                "Security": [
                    "SecurityModule.swift": """
                    import AlulaWeb
                    public struct SecurityModule: AlulaModule {
                    public let middleware: [MiddlewareRegistration]
                    public init(sessions: Bool) {
                    let session: [any Middleware] = sessions ? [Sessions()] : []
                    self.middleware = MiddlewareRegistration.lane(.authenticated, session + [Authentication()])
                    }
                    }
                    """
                ]
            ])
        #expect(result.exitCode == 0)
        #expect(!result.diagnostics.contains("pipeline lane"), "\(result.diagnostics)")
    }

    @Test("the two lanes dispatch provides need no declaration")
    func canonicalLanesNeedNoDeclaration() throws {
        // `.default` exists whether or not anything registers into it, and
        // `.public` means "explicitly no lanes" — DispatchBuilder supplies
        // both, so naming them is never a mistake.
        let result = try generate([
            "AppModule.swift": """
            import AlulaWeb
            @Controller("/x", pipelines: [.default])
            struct A {
            @GetRoute("/a")
            func a(_ context: RequestContext) -> String { "a" }
            @GetRoute("/b", pipelines: [.public])
            func b(_ context: RequestContext) -> String { "b" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(!result.diagnostics.contains("pipeline lane"))
    }

    @Test("a computed lane name silences the check rather than guessing")
    func computedLaneStaysQuiet() throws {
        // One unknowable declaration makes the whole set unknowable: it might
        // be the very lane the route is asking for.
        let result = try generate([
            "AppModule.swift": """
            import AlulaWeb
            struct AppModule: AlulaModule {
            let middleware = MiddlewareRegistration.lane(PipelineLane(computedName), [AuditLog()])
            }
            @Controller("/admin", pipelines: ["audit"])
            struct AdminController {
            @GetRoute("/")
            func index(_ context: RequestContext) -> String { "x" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(!result.diagnostics.contains("pipeline lane"))
    }

    // MARK: - Removed `scope:` / `qualifier:` arguments

    @Test("`scope: .singleton` is a build error naming the migration")
    func removedScopeArgumentDiagnosed() throws {
        // The surviving lifetime is the common case, not the exotic one: an
        // application that never touched `.scoped` still wrote
        // `@Service(scope: .singleton)` because the argument existed. Without
        // this, upgrading to 0.20.0 means "extra argument in call" at every
        // one of those sites, which says nothing about what to do.
        let result = try generate([
            "Sources.swift": """
            import AlulaCore
            @Service(scope: .singleton) final class Reports: Sendable {
            init() {}
            }
            """
        ])
        #expect(result.exitCode != 0)
        #expect(result.diagnostics.contains("Reports"))
        #expect(result.diagnostics.contains("removed in 0.20.0"))
        #expect(result.diagnostics.contains("[ALU-DI-1013]"))
        #expect(result.diagnostics.contains("delete the argument: `@Service`"))
        // The migration prose survives the broadening: where the other
        // lifetimes went is still what the author needs to know.
        #expect(result.diagnostics.contains("RequestContext"))
    }

    @Test("a removed lifetime is a build error that says what to do instead")
    func removedLifetimeDiagnosed() throws {
        // This check used to catch captive dependencies — a singleton
        // injecting a `.scoped` component. That class cannot happen now:
        // there is one lifetime, so a singleton has nothing shorter-lived to
        // capture. What survives is the migration case, and 0.20.0 widened it:
        // with `Lifetime` deleted and the argument gone from the macro, source
        // carrying `.scoped` otherwise meets "extra argument in call", which
        // says what is malformed and nothing about what to do.
        let result = try generate([
            "Captive.swift": """
            import AlulaCore
            @Repository(scope: .scoped) final class UserRepository: Sendable {
            init() {}
            }
            """
        ])
        #expect(result.exitCode != 0)
        #expect(result.diagnostics.contains("UserRepository"))
        #expect(result.diagnostics.contains("[ALU-DI-1013]"))
        #expect(result.diagnostics.contains("RequestContext"))
    }

    @Test("`.transient` is diagnosed the same way")
    func removedTransientDiagnosed() throws {
        let result = try generate([
            "Old.swift": """
            import AlulaCore
            @Service(scope: .transient) final class Builder: Sendable {
            init() {}
            }
            """
        ])
        #expect(result.exitCode != 0)
        #expect(result.diagnostics.contains(".transient"))
    }

    // MARK: - Static route manifest

    @Test("routes are scanned into a static manifest, with controller paths combined")
    func emitsRouteManifest() throws {
        let result = try generate([
            "UserController.swift": """
            import AlulaWeb
            @Controller("/users")
            struct UserController {
            @GetRoute("/:id")
            func show(_ context: RequestContext) -> String { "x" }
            @PostRoute("")
            func create(_ context: RequestContext) -> String { "y" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("AlulaRouteManifest"))
        // The combination rule is the macro's, applied by the same parser.
        #expect(result.generated.contains(#"path: "/users/:id""#))
        #expect(result.generated.contains(#"path: "/users""#))
        #expect(result.generated.contains(#"method: "GET""#))
        #expect(result.generated.contains(#"method: "POST""#))
        #expect(result.generated.contains("AppModule.UserController.show"))
    }

    @Test("a route's own pipelines replace the controller's in the manifest")
    func manifestResolvesPipelines() throws {
        // Replacement, not addition — the rule a route relies on to say
        // "this one is public" under an authenticated controller.
        let result = try generate([
            "DashboardController.swift": """
            import AlulaWeb
            @Controller("/dashboard", pipelines: [.authenticated])
            struct DashboardController {
            @GetRoute("/admin")
            func admin(_ context: RequestContext) -> String { "a" }
            @GetRoute("/", pipelines: [.public])
            func index(_ context: RequestContext) -> String { "i" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("[.authenticated]"))
        #expect(result.generated.contains("[.public]"))
    }

    @Test("a WebSocket route is marked as an upgrade")
    func manifestMarksUpgrades() throws {
        let result = try generate([
            "SocketController.swift": """
            import AlulaWeb
            @Controller("/live")
            struct SocketController {
            @WebSocketRoute("/feed")
            func feed(_ context: RequestContext) -> some WebSocketUpgradeHandler { fatalError() }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("isUpgrade: true"))
        // An upgrade rides a GET (RFC 6455 §4.1).
        #expect(result.generated.contains(#"method: "GET""#))
    }

    @Test("a route the macro would reject does not reach the manifest")
    func rejectedRoutesAreOmitted() throws {
        // The generator scans silently — @Controller already diagnoses this,
        // and both run in the same build, so reporting here would say it
        // twice. What matters is that the bad route is not manifested either.
        let result = try generate([
            "BadController.swift": """
            import AlulaWeb
            @Controller("/bad")
            struct BadController {
            @GetRoute("/ok")
            func ok(_ context: RequestContext) -> String { "ok" }
            @GetRoute("/static")
            static func wrong(_ context: RequestContext) -> String { "no" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains(#"path: "/bad/ok""#))
        #expect(!result.generated.contains(#"path: "/bad/static""#))
        #expect(
            !result.diagnostics.contains("must be an instance method"),
            "the macro owns this diagnostic; the generator must not repeat it")
    }

    // MARK: - Lane manifest

    @Test("lane declarations are scanned with their middleware in order")
    func emitsLanes() throws {
        let result = try generate([
            "AppModule.swift": """
            import AlulaWeb
            struct AppModule: AlulaModule {
            let middleware = MiddlewareRegistration.lane(.default, [RequestTiming(), Authentication()])
            + MiddlewareRegistration.lane("admin", [RequireAdmin()])
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("AlulaRouteManifest"))
        // Unnamed form is the default lane; order is the declaration's content.
        #expect(result.generated.contains(#"name: "default", middleware: ["RequestTiming", "Authentication"]"#))
        #expect(result.generated.contains(#"name: "admin", middleware: ["RequireAdmin"]"#))
        // The enclosing type is what decides whether the lane exists at all.
        #expect(result.generated.contains(#"declaredIn: "AppModule""#))
    }

    @Test("a canonical lane member is named, not left as source text")
    func namesCanonicalLanes() throws {
        let result = try generate([
            "SecurityModule.swift": """
            import AlulaWeb
            struct SecurityModule: AlulaModule {
            let middleware = MiddlewareRegistration.lane(.authenticated, [Authentication(), RequireAuthentication()])
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains(#"name: "authenticated""#))
        #expect(result.generated.contains(#"["Authentication", "RequireAuthentication"]"#))
    }

    @Test("an empty block still declares its lane")
    func emptyBlockDeclaresLane() throws {
        // The motivating case: a static-asset lane that runs nothing. Before
        // the framework registered a marker for it, the block left no trace
        // and any route naming the lane failed validation.
        let result = try generate([
            "AssetsModule.swift": """
            import AlulaWeb
            struct AssetsModule: AlulaModule {
            let middleware = MiddlewareRegistration.lane("assets", [])
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains(#"name: "assets", middleware: []"#))
    }

    @Test("two declarations of one lane are kept separate, in order")
    func lanesCompose() throws {
        // pipeline() composes rather than conflicts: a framework module
        // installs its middleware and the application appends. Flattening
        // them here would lose the only thing the declaration carries.
        let result = try generate([
            "A.swift": """
            import AlulaWeb
            struct FrameworkModule: AlulaModule {
            let middleware = MiddlewareRegistration.lane(.default, [Authentication()])
            }
            """,
            "B.swift": """
            import AlulaWeb
            struct AppModule: AlulaModule {
            let middleware = MiddlewareRegistration.lane(.default, [RequestLogging()])
            }
            """,
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains(#"middleware: ["Authentication"], declaredIn: "FrameworkModule""#))
        #expect(result.generated.contains(#"middleware: ["RequestLogging"], declaredIn: "AppModule""#))
    }

    @Test("a components-only target still gets a manifest, with empty route and lane lists")
    func componentsOnlyTargetGetsManifest() throws {
        // A library of @Service types has no routes and declares no lanes,
        // and still needs its component list: that is the part a composition
        // function is built from. Empty arrays are the honest answer, not a
        // reason to emit nothing.
        let result = try generate([
            "UserService.swift": """
            import AlulaCore
            @Service final class UserService: Sendable {
            init() {}
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("AlulaRouteManifest"))
        #expect(result.generated.contains("public static let routes: [Entry] = [\n    ]"))
        #expect(
            result.generated.contains(
                #"Component(typeName: "UserService", stereotype: "service""#))
    }

    @Test("a target with no Alula surface at all emits no manifest")
    func emptyTargetEmitsNoManifest() throws {
        let result = try generate([
            "Plain.swift": """
            struct JustAStruct {}
            """
        ])
        #expect(result.exitCode == 0)
        #expect(!result.generated.contains("AlulaRouteManifest"))
    }

    // MARK: - Module order

    @Test("a dependency's lanes come before its dependent's, not in file order")
    func lanesFollowModuleOrder() throws {
        // The defect this exists to catch: a lane's chain runs in module
        // order, which is dependency order — dependencies are built first.
        // Scan order follows the file list, which put the app's own module
        // first and reversed the real chain.
        let result = try generate([
            "A_AppModule.swift": """
            import AlulaWeb
            struct AppModule: AlulaModule {
            static var dependencies: [any AlulaModule.Type] { [SecurityModule.self] }
            let middleware = MiddlewareRegistration.lane(.default, [RequestLogging()])
            }
            """,
            "B_SecurityModule.swift": """
            import AlulaWeb
            struct SecurityModule: AlulaModule {
            let middleware = MiddlewareRegistration.lane(.default, [Authentication()])
            }
            """,
        ])
        #expect(result.exitCode == 0)
        let authentication = try #require(result.generated.range(of: #""Authentication""#))
        let logging = try #require(result.generated.range(of: #""RequestLogging""#))
        #expect(
            authentication.lowerBound < logging.lowerBound,
            "AppModule depends on SecurityModule, so SecurityModule configures first")
    }

    @Test("the module graph is emitted, dependencies as written")
    func emitsModuleGraph() throws {
        let result = try generate([
            "AppModule.swift": """
            import AlulaWeb
            struct AppModule: AlulaModule {
            static var dependencies: [any AlulaModule.Type] {
            [
            PostgresDataModule<PrimaryDataSource>.self,
            AlulaPubSubModule.self,
            ]
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        // As written, generic argument and all: matching strips it, but the
        // composer has to construct the type that was named.
        #expect(
            result.generated.contains(
                #"name: "AppModule", dependencies: ["PostgresDataModule<PrimaryDataSource>", "AlulaPubSubModule"]"#
            ))
    }

    @Test("a module with no dependencies is still an edge in the graph")
    func moduleWithoutDependencies() throws {
        let result = try generate([
            "Bare.swift": """
            import AlulaWeb
            struct BareModule: AlulaModule {
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains(#"name: "BareModule", dependencies: []"#))
    }

    @Test("a dependency cycle between modules does not hang the sort")
    func cyclicModulesTerminate() throws {
        // Reporting the cycle is the bootstrap's job; this only has to not
        // loop forever while producing something.
        let result = try generate([
            "Cycle.swift": """
            import AlulaWeb
            struct A: AlulaModule {
            static var dependencies: [any AlulaModule.Type] { [B.self] }
            }
            struct B: AlulaModule {
            static var dependencies: [any AlulaModule.Type] { [A.self] }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("moduleGraph"))
    }

    // MARK: - The component list

    @Test("the manifest's data rows are exactly this — indentation included")
    func manifestRowsAreGolden() throws {
        // Same hazard the registration body's golden test exists for: the
        // manifest is built by appending string literals, so a cleanup pass
        // can collapse its indentation while every `contains` test still
        // passes. This pins the rows rather than the whole block, so a
        // doc-comment edit is not a failure but a shape regression is.
        let result = try generate([
            "Sources.swift": """
            import AlulaWeb
            @Controller("/users")
            struct UserController {
                @Inject var repo: UserRepository
                @GetRoute("/:id")
                func show(_ context: RequestContext) -> String { "x" }
            }
            @Repository
            struct UserRepository {}
            """
        ])
        #expect(result.exitCode == 0)

        let start = try #require(
            result.generated.range(of: "    public static let components: [Component] = [")
        ).lowerBound
        let rest = result.generated[start...]
        let end = try #require(rest.range(of: "\n    ]")).upperBound
        #expect(
            String(result.generated[start..<end]) == """
                    public static let components: [Component] = [
                        Component(typeName: "UserController", stereotype: "controller", dependencies: ["UserRepository"], isModuleRegistered: false, module: "AppModule"),
                        Component(typeName: "UserRepository", stereotype: "repository", dependencies: [], isModuleRegistered: false, module: "AppModule"),
                    ]
                """)
    }

    @Test("a component's stereotype follows its attribute")
    func stereotypeFollowsAttribute() throws {
        let result = try generate([
            "Sources.swift": """
            import AlulaWeb
            @Service struct A: Sendable {}
            @Repository struct B: Sendable {}
            @Component struct C: Sendable {}
            @Middleware struct D: Sendable {}
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains(#"typeName: "A", stereotype: "service""#))
        #expect(result.generated.contains(#"typeName: "B", stereotype: "repository""#))
        // @Component passes no `stereotype:` and takes the parameter's
        // default, so the manifest must say the same thing.
        #expect(result.generated.contains(#"typeName: "C", stereotype: "component""#))
        #expect(result.generated.contains(#"typeName: "D", stereotype: "middleware""#))
    }

    @Test("a module-registered component is listed, and flagged")
    func moduleRegisteredComponentIsFlagged() throws {
        // It is not built by the composition root — that is what the marker means —
        // but it is still part of the graph, and a composition function has
        // to know it exists to order anything that depends on it.
        let result = try generate([
            "Sources.swift": """
            import AlulaWeb
            // alula:module-registered
            @Middleware struct Authentication: Sendable {}
            """
        ])
        #expect(result.exitCode == 0)
        #expect(!result.generated.contains("try Authentication._alulaRegister"))
        #expect(
            result.generated.contains(
                #"typeName: "Authentication", stereotype: "middleware", dependencies: [], isModuleRegistered: true"#
            ))
    }

    @Test("a type-level qualifier: is a build error naming the migration")
    func removedQualifierArgumentDiagnosed() throws {
        // This used to assert the qualifier reached the Actuator descriptor.
        // 0.20.0 removed the argument — it expanded to nothing, because
        // composition wires by type — so what the generator owes the author is
        // the migration, not the round-trip.
        let result = try generate([
            "Sources.swift": """
            import AlulaCore
            @Repository(qualifier: "primary") struct Pool: Sendable {}
            """
        ])
        #expect(result.exitCode != 0)
        #expect(result.diagnostics.contains("Pool"))
        #expect(result.diagnostics.contains("removed in 0.20.0"))
        #expect(result.diagnostics.contains("[ALU-DI-1014]"))
        #expect(result.diagnostics.contains("delete the argument: `@Repository`"))
        // Both qualifiers went in 0.20.0, and an author deleting this one will
        // hit the other next, so the message says so rather than letting them
        // find out one call site at a time.
        #expect(result.diagnostics.contains("@Inject"))
    }

    @Test("`qualifier: nil` is diagnosed too — passing it at all is the error")
    func removedQualifierArgumentSpelledNilDiagnosed() throws {
        // The scan used to read a literal `nil` as "absent", which was right
        // when the field fed emission and wrong now: the call site is still
        // passing an argument that no longer exists.
        let result = try generate([
            "Sources.swift": """
            import AlulaCore
            @Component(qualifier: nil) struct Pool: Sendable {}
            """
        ])
        #expect(result.exitCode != 0)
        #expect(result.diagnostics.contains("removed in 0.20.0"))
    }

    // MARK: - Failure modes

    @Test("an unreadable source file is skipped with a warning, not a crash")
    func unreadableFileWarns() throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alulagen-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let output = workspace.appendingPathComponent("Out.swift")
        let manifest: [String: Any] = [
            "targetModuleName": "AppModule",
            "modules": [
                [
                    "name": "AppModule",
                    "files": [workspace.appendingPathComponent("gone.swift").path],
                ]
            ],
            "output": output.path,
        ]
        let manifestPath = workspace.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: []).write(to: manifestPath)

        let process = Process()
        process.executableURL = Self.executable
        process.arguments = [manifestPath.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        let diagnostics =
            String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        #expect(process.terminationStatus == 0, "a missing source must not fail the build")
        #expect(diagnostics.lowercased().contains("warning"))
    }

    @Test("a malformed manifest exits with a usage error rather than crashing")
    func malformedManifestExitsCleanly() throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alulagen-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let manifestPath = workspace.appendingPathComponent("manifest.json")
        try "{ not json".write(to: manifestPath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = Self.executable
        process.arguments = [manifestPath.path]
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 2)
    }

    @Test("no arguments exits with usage")
    func noArgumentsExitsWithUsage() throws {
        let process = Process()
        process.executableURL = Self.executable
        process.arguments = []
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 2)
    }
}
