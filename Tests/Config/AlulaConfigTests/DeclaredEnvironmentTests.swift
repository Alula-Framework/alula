import Foundation
import Testing

@testable import AlulaConfig

/// "Which overlay" and "is this a development box" are different questions,
/// and an unset `ALULA_ENV` answers them differently: `dev`, and no.
@Suite("Declared environment")
struct DeclaredEnvironmentTests {

    private func loaded(
        environment: AlulaEnvironment? = nil, processEnvironment: [String: String]
    ) throws -> Configuration {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alula-declared-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "app:\n  name: t\n".write(
            to: directory.appendingPathComponent("alula.yaml"), atomically: true, encoding: .utf8)
        return try Configuration.load(
            from: directory, environment: environment, processEnvironment: processEnvironment)
    }

    @Test("an unset ALULA_ENV loads the dev overlay but declares nothing")
    func unsetIsNotDevelopment() throws {
        let configuration = try loaded(processEnvironment: [:])
        #expect(configuration.environment == .dev)
        // The real process environment is not consulted: `load` already knows.
        #expect(configuration.declaredEnvironment(processEnvironment: ["ALULA_ENV": "dev"]) == nil)
        #expect(!configuration.isExplicitlyDevelopment(processEnvironment: ["ALULA_ENV": "dev"]))
    }

    @Test("ALULA_ENV naming a development environment is explicit development")
    func declaredDevelopment() throws {
        for name in ["dev", "development", "test", "local", "DEV"] {
            let configuration = try loaded(processEnvironment: ["ALULA_ENV": name])
            #expect(configuration.declaredEnvironment(processEnvironment: [:])?.rawValue == name)
            #expect(configuration.isExplicitlyDevelopment(processEnvironment: [:]), "\(name)")
        }
    }

    @Test("any other environment is not development")
    func declaredOther() throws {
        for name in ["prod", "production", "staging", "qa", "prd"] {
            let configuration = try loaded(processEnvironment: ["ALULA_ENV": name])
            #expect(!configuration.isExplicitlyDevelopment(processEnvironment: [:]), "\(name)")
        }
    }

    @Test("an environment named in code is a declaration")
    func namedInCode() throws {
        #expect(try loaded(environment: .dev, processEnvironment: [:]).isExplicitlyDevelopment(processEnvironment: [:]))
        #expect(!(try loaded(environment: .prod, processEnvironment: ["ALULA_ENV": "dev"]).isExplicitlyDevelopment(processEnvironment: [:])))
        let handBuilt = Configuration(sources: [], environment: .test)
        #expect(handBuilt.isExplicitlyDevelopment(processEnvironment: [:]))
    }

    @Test("a hand-assembled configuration without one reads ALULA_ENV")
    func handAssembledReadsTheVariable() {
        let configuration = Configuration(values: [:])
        #expect(configuration.declaredEnvironment(processEnvironment: [:]) == nil)
        #expect(configuration.declaredEnvironment(processEnvironment: ["ALULA_ENV": ""]) == nil)
        #expect(configuration.isExplicitlyDevelopment(processEnvironment: ["ALULA_ENV": "dev"]))
        #expect(!configuration.isExplicitlyDevelopment(processEnvironment: ["ALULA_ENV": "prod"]))
    }
}
