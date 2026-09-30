import AlulaCore
import AlulaDiagnostics
import AlulaWeb
import AlulaWebTesting
import Foundation
import Testing

@testable import AlulaSecurityCore

@Suite("Module wiring and configuration")
struct ModuleTests {
    private var minimalConfig: Configuration {
        Configuration(values: [
            "security.oidc.issuer": testIssuer,
            "security.oidc.audience": testAudience,
        ])
    }

    @Test("OIDC settings accept the kebab-case spelling the rest of Alula uses")
    func kebabCaseKeysAreAccepted() throws {
        // Every other namespace is kebab-case, so `jwks-url` is what someone
        // writes from habit — and it used to be read as absent, handing back
        // the default for a key they had set. `Configuration` cannot
        // enumerate keys, so nothing could have caught that.
        let kebab = try OIDCSecurityConfiguration(
            configuration: Configuration(values: [
                "security.oidc.issuer": testIssuer,
                "security.oidc.audience": testAudience,
                "security.oidc.jwks-url": "https://idp.example.com/keys",
                "security.oidc.clock-skew-leeway": "120",
                "security.oidc.roles-claim": "my_roles",
            ]))
        #expect(kebab.jwksURL?.absoluteString == "https://idp.example.com/keys")
        #expect(kebab.clockSkewLeeway == 120)
        #expect(kebab.rolesClaims == ["my_roles"])
    }

    @Test("the snake_case spelling that shipped is refused, naming the kebab-case key")
    func snakeCaseKeysAreRefused() {
        #expect(
            throws: ConfigError.renamedKey(
                formerKey: "security.oidc.jwks_url", currentKey: "security.oidc.jwks-url",
                provider: "TestConfigSource")
        ) {
            try OIDCSecurityConfiguration(
                configuration: Configuration(values: [
                    "security.oidc.issuer": testIssuer,
                    "security.oidc.audience": testAudience,
                    "security.oidc.jwks_url": "https://idp.example.com/legacy",
                ]))
        }
    }

    @Test("the snake_case spelling is refused even when the kebab-case one is set too")
    func snakeCaseRefusedBesideKebabCase() {
        #expect(
            throws: ConfigError.renamedKey(
                formerKey: "security.oidc.jwks_max_stale", currentKey: "security.oidc.jwks-max-stale",
                provider: "TestConfigSource")
        ) {
            try OIDCSecurityConfiguration(
                configuration: Configuration(values: [
                    "security.oidc.issuer": testIssuer,
                    "security.oidc.audience": testAudience,
                    "security.oidc.jwks_max_stale": "111",
                    "security.oidc.jwks-max-stale": "222",
                ]))
        }
    }

    @Test("ALULA_SECURITY_OIDC_JWKS_URL is the kebab-case key's own variable, and is read")
    func environmentVariableIsTheNewKey() throws {
        let configuration = Configuration(sources: [
            EnvironmentVariablesSource(environment: [
                "ALULA_SECURITY_OIDC_ISSUER": testIssuer,
                "ALULA_SECURITY_OIDC_AUDIENCE": testAudience,
                "ALULA_SECURITY_OIDC_JWKS_URL": "https://idp.example.com/keys",
            ])
        ])
        let config = try OIDCSecurityConfiguration(configuration: configuration)
        #expect(config.jwksURL?.absoluteString == "https://idp.example.com/keys")
    }

    @Test("the security module declares middleware and lanes, but no validator")
    func securityModuleRegistersAuthenticationOnly() throws {
        // Declared as values now: the composition root hands them to
        // AlulaWebModule alongside every other module's.
        let module = try AlulaSecurityModule(validator: StubValidator(principalsByToken: [:]))

        // The principal needs no registration at all: it rides
        // `RequestContext.identity` as a typed value the authentication
        // middleware writes into the request context.
        #expect(module.middleware.contains { $0.name.contains("Authentication") })
        // All three canonical lanes, so `pipelines: [.authenticated]` resolves.
        #expect(
            Set(module.middleware.map(\.lane)) == [.default, .authentication, .authenticated])

        #expect(module.service == nil, "JWKS maintenance belongs to AlulaOIDCModule")
    }

    @Test("no validator, no strategies and no sessions stops the start with ALU-SEC-6003")
    func nothingAuthenticatesIsCoded() throws {
        // This was a `precondition`: the documented "composition stops at
        // startup saying so" was a trap and a backtrace, not a report.
        let error = try #require(throws: NothingAuthenticatesError.self) {
            try AlulaSecurityModule(validator: nil)
        }
        let diagnostic: any StartupDiagnostic = error
        let code = try #require(diagnostic.diagnosticCode)
        let rendered = Diagnostic(code, diagnostic.startupDiagnostic, at: nil).rendered
        #expect(rendered.contains("[ALU-SEC-6003]"))
        #expect(rendered.contains("AlulaOIDCModule"))
        #expect(rendered.contains("AlulaSessionsModule"))
    }

    @Test("AlulaOIDCModule supplies the validator and owns JWKS maintenance")
    func oidcModuleSuppliesValidator() throws {
        let oidc = try AlulaOIDCModule(configuration: minimalConfig)

        // The validator is a value the OIDC module holds; the composition root
        // wires it into AlulaSecurityModule by type.
        #expect(oidc.tokenValidator is OIDCTokenValidator)
        #expect(oidc.service != nil, "OIDC owns the JWKS maintenance service")

        // And the security module built from that validator declares its
        // middleware.
        #expect(
            try AlulaSecurityModule(validator: oidc.tokenValidator).middleware
                .contains { $0.name.contains("Authentication") }
        )
    }

    @Test("missing OIDC configuration fails at startup, not first request")
    func missingConfiguration() {
        // Earlier than it used to be: the validator is built when the module
        // is, so bad configuration fails at composition — at startup, not at
        // the first request.
        #expect(throws: (any Error).self) {
            try AlulaOIDCModule(configuration: Configuration())
        }
        #expect(throws: (any Error).self) {
            try AlulaOIDCModule(
                configuration: Configuration(values: ["security.oidc.issuer": testIssuer]))
        }
    }

    @Test("any validator works: supply one and omit AlulaOIDCModule — no ordering")
    func customValidatorNeedsNoOrdering() throws {
        let stub = StubValidator(principalsByToken: ["t": testPrincipal()])

        // You hand the validator to the module directly, so there is no
        // registration race to lose and no ordering dependence — and no
        // security.oidc.* configuration is demanded when AlulaOIDCModule is
        // not composed. "No validator" is not a state the module can reach:
        // the initializer requires one.
        let security = try AlulaSecurityModule(validator: stub)
        #expect(
            security.middleware.contains { $0.name.contains("Authentication") },
            "middleware still declared"
        )
    }

    @Test("configuration keys map onto OIDCSecurityConfiguration with documented defaults")
    func configurationDefaults() throws {
        let config = try OIDCSecurityConfiguration(configuration: minimalConfig)
        #expect(config.issuer == testIssuer)
        #expect(config.audience == testAudience)
        #expect(config.jwksURL == nil)
        #expect(config.jwksCacheTTL == 3600)
        #expect(config.clockSkewLeeway == 60)
        #expect(config.jwksRefreshCooldown == 30)
        #expect(config.rolesClaims == ["roles", "groups", "realm_access.roles"])
        #expect(config.scopesClaims == ["scope", "scp"])
    }

    @Test("every documented key is read")
    func configurationOverrides() throws {
        let config = try OIDCSecurityConfiguration(
            configuration: Configuration(values: [
                "security.oidc.issuer": "https://idp",
                "security.oidc.audience": "app",
                "security.oidc.jwks-url": "https://idp/keys",
                "security.oidc.jwks-cache-ttl": "600",
                "security.oidc.clock-skew-leeway": "5",
                "security.oidc.jwks-refresh-cooldown": "120",
                "security.oidc.roles-claim": "https://example.com/roles, groups",
                "security.oidc.scopes-claim": "scope",
            ])
        )
        #expect(config.jwksURL == URL(string: "https://idp/keys"))
        #expect(config.jwksCacheTTL == 600)
        #expect(config.clockSkewLeeway == 5)
        #expect(config.jwksRefreshCooldown == 120)
        #expect(config.rolesClaims == ["https://example.com/roles", "groups"])
        #expect(config.scopesClaims == ["scope"])
    }

    @Test("empty issuer or audience is rejected")
    func emptyRequiredValues() {
        #expect(throws: (any Error).self) {
            try OIDCSecurityConfiguration(issuer: "  ", audience: "app")
        }
        #expect(throws: (any Error).self) {
            try OIDCSecurityConfiguration(issuer: "https://idp", audience: "")
        }
    }

    @Test("the JWKS maintenance service pre-warms the cache at startup")
    func maintenancePrewarm() async throws {
        let identity = TestIdentity(kid: "svc-key")
        let source = try InMemoryJWKSSource(json: jwksJSON([identity]))
        let configuration = try OIDCSecurityConfiguration(issuer: testIssuer, audience: testAudience)
        let validator = OIDCTokenValidator(configuration: configuration, jwksSource: source)

        // The service takes the validator it maintains — no container, and
        // so nothing to discover and no cast that can fail.
        let service = JWKSMaintenanceService(validator: validator)
        let run = Task { try await service.run() }

        // Poll until the pre-warm fetch lands.
        for _ in 0..<100 where source.fetchCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(source.fetchCount == 1)

        run.cancel()
        _ = try? await run.value
    }
}
