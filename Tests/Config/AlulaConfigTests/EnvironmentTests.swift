import Testing
@testable import AlulaConfig

@Suite("AlulaEnvironment")
struct AlulaEnvironmentTests {

    @Test("unset ALULA_ENV defaults to dev — a valid local state, never a throw")
    func unsetDefaultsToDev() {
        #expect(AlulaEnvironment.current(from: [:]) == .dev)
    }

    @Test("the standard environments resolve from their raw values")
    func standardEnvironments() {
        for env in AlulaEnvironment.standard {
            #expect(AlulaEnvironment.current(from: ["ALULA_ENV": env.rawValue]) == env)
        }
    }

    @Test("an unset or empty ALULA_ENV resolves to dev")
    func absentDefaultsToDev() {
        #expect(AlulaEnvironment.current(from: [:]) == .dev)
        #expect(AlulaEnvironment.current(from: ["ALULA_ENV": ""]) == .dev)
    }

    @Test("a non-standard value resolves to itself, not silently to dev")
    func nonStandardResolvesToItself() {
        // Collapsing an unknown name to `dev` would load development
        // configuration under a production-shaped name, silently. Resolving
        // to itself means the missing alula-qa.yaml is visible instead.
        #expect(AlulaEnvironment.current(from: ["ALULA_ENV": "qa"]) == AlulaEnvironment("qa"))
        #expect(AlulaEnvironment.current(from: ["ALULA_ENV": "production"]).rawValue == "production")
        #expect(AlulaEnvironment.current(from: ["ALULA_ENV": "production"]) != .prod)
    }

    @Test("an app can define its own environments")
    func extensibility() {
        let qa = AlulaEnvironment("qa")
        #expect(qa.rawValue == "qa")
        #expect(AlulaEnvironment.current(from: ["ALULA_ENV": "qa"]) == qa)
        #expect(!AlulaEnvironment.standard.contains(qa))
    }

    @Test("current() reads the real process environment without throwing")
    func currentReadsProcess() {
        // Can't assert a specific value without mutating global state; the
        // contract is "always resolves, never throws".
        _ = AlulaEnvironment.current()
    }
}

@Suite("EnvironmentVariablesSource")
struct EnvironmentVariablesSourceTests {

    @Test("the fixed transform: uppercase, dots to underscores, ALULA_ prefix")
    func transform() {
        #expect(EnvironmentVariablesSource.variableName(for: "datasource.url") == "ALULA_DATASOURCE_URL")
        #expect(EnvironmentVariablesSource.variableName(for: "datasource.pool_size") == "ALULA_DATASOURCE_POOL_SIZE")
        #expect(EnvironmentVariablesSource.variableName(for: "server.port") == "ALULA_SERVER_PORT")
        #expect(EnvironmentVariablesSource.variableName(for: "key") == "ALULA_KEY")
    }

    @Test("keys resolve through the transform")
    func resolution() {
        let source = EnvironmentVariablesSource(environment: [
            "ALULA_DATASOURCE_URL": "postgres://injected",
            "ALULA_SERVER_PORT": "9999",
            "UNPREFIXED": "ignored",
        ])
        #expect(source.rawValue(for: "datasource.url") == "postgres://injected")
        #expect(source.rawValue(for: "server.port") == "9999")
        #expect(source.rawValue(for: "unprefixed") == nil, "only ALULA_-prefixed names participate")
        #expect(source.rawValue(for: "missing.key") == nil)
    }

    @Test("set-but-empty is a present value — it overrides lower layers")
    func emptyValueIsPresent() throws {
        let config = Configuration(sources: [
            EnvironmentVariablesSource(environment: ["ALULA_FEATURE_FLAG": ""]),
            TestConfigSource(["feature.flag": "from-file"]),
        ])
        #expect(try config.get("feature.flag", as: String.self) == "")
    }

    @Test("defaults to a snapshot of the real process environment")
    func defaultSnapshot() {
        _ = EnvironmentVariablesSource()  // constructible without arguments
    }
}
