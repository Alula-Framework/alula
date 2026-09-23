import Foundation
import Testing
@testable import AlulaConfig

/// Integration tests for `Configuration.load` — real files in a temp
/// directory, explicit process-environment dictionaries, no global state.
@Suite("Configuration.load")
struct LoaderTests {

    /// Creates a unique temp directory, writes the given files, runs `body`,
    /// and removes the directory afterwards.
    private func withConfigDirectory<T>(
        files: [String: String],
        _ body: (URL) throws -> T
    ) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alula-config-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, contents) in files {
            try contents.write(
                to: directory.appendingPathComponent(name),
                atomically: true, encoding: .utf8
            )
        }
        return try body(directory)
    }

    private let baseYAML = """
    datasource:
      url: "postgres://localhost:5432/alula_dev"
      pool_size: 5
    server:
      port: 8080
    """

    @Test("base only: dev resolution straight from alula.yaml")
    func baseOnly() throws {
        try withConfigDirectory(files: ["alula.yaml": baseYAML]) { directory in
            let config = try Configuration.load(from: directory, processEnvironment: [:])
            #expect(config.environment == .dev)
            #expect(try config.get("datasource.url", as: String.self) == "postgres://localhost:5432/alula_dev")
            #expect(try config.get("datasource.pool_size", as: Int.self) == 5)
            #expect(try config.get("server.port", as: Int.self) == 8080)
        }
    }

    @Test("ALULA_ENV selects the environment file; overrides are key-by-key")
    func environmentLayering() throws {
        let prodYAML = """
        datasource:
          pool_size: 50
        """
        try withConfigDirectory(files: ["alula.yaml": baseYAML, "alula-prod.yaml": prodYAML]) { directory in
            let config = try Configuration.load(
                from: directory,
                processEnvironment: ["ALULA_ENV": "prod"]
            )
            #expect(config.environment == .prod)
            // Overridden by alula-prod.yaml:
            #expect(try config.get("datasource.pool_size", as: Int.self) == 50)
            // Untouched keys fall through to base:
            #expect(try config.get("datasource.url", as: String.self) == "postgres://localhost:5432/alula_dev")
            #expect(try config.get("server.port", as: Int.self) == 8080)
        }
    }

    @Test("env vars beat both files — the always-wins escape hatch")
    func envVarsWin() throws {
        let prodYAML = "server:\n  port: 9090"
        try withConfigDirectory(files: ["alula.yaml": baseYAML, "alula-prod.yaml": prodYAML]) { directory in
            let config = try Configuration.load(
                from: directory,
                processEnvironment: [
                    "ALULA_ENV": "prod",
                    "ALULA_SERVER_PORT": "443",
                ]
            )
            #expect(try config.get("server.port", as: Int.self) == 443)
        }
    }

    @Test("a missing alula-{env}.yaml is not an error")
    func missingEnvironmentFileIsFine() throws {
        try withConfigDirectory(files: ["alula.yaml": baseYAML]) { directory in
            let config = try Configuration.load(
                from: directory,
                processEnvironment: ["ALULA_ENV": "staging"]
            )
            #expect(config.environment == .staging)
            #expect(try config.get("server.port", as: Int.self) == 8080)
        }
    }

    @Test("a missing alula.yaml is an error naming the expected path")
    func missingBaseFileThrows() throws {
        try withConfigDirectory(files: [:]) { directory in
            do {
                _ = try Configuration.load(from: directory, processEnvironment: [:])
                Issue.record("expected missingBaseFile")
            } catch let error as ConfigLoadError {
                guard case .missingBaseFile(let path) = error else {
                    Issue.record("wrong case: \(error)")
                    return
                }
                #expect(path.hasSuffix("alula.yaml"))
            }
        }
    }

    @Test("explicit environment parameter overrides ALULA_ENV")
    func explicitEnvironmentWins() throws {
        let testYAML = "server:\n  port: 1234"
        try withConfigDirectory(files: ["alula.yaml": baseYAML, "alula-test.yaml": testYAML]) { directory in
            let config = try Configuration.load(
                from: directory,
                environment: .test,
                processEnvironment: ["ALULA_ENV": "prod"]
            )
            #expect(config.environment == .test)
            #expect(try config.get("server.port", as: Int.self) == 1234)
        }
    }

    @Test("the design doc's full prod scenario, end to end")
    func designDocProdScenario() throws {
        // alula-prod.yaml references the env var; the env var layer would
        // win anyway, but the substitution keeps the file resolvable.
        let prodYAML = """
        datasource:
          url: "${ALULA_DATASOURCE_URL}"
          pool_size: 50
        """
        try withConfigDirectory(files: ["alula.yaml": baseYAML, "alula-prod.yaml": prodYAML]) { directory in
            let config = try Configuration.load(
                from: directory,
                processEnvironment: [
                    "ALULA_ENV": "prod",
                    "ALULA_DATASOURCE_URL": "postgres://prod-cluster:5432/alula",
                ]
            )
            #expect(try config.get("datasource.url", as: String.self) == "postgres://prod-cluster:5432/alula")
            #expect(try config.get("datasource.pool_size", as: Int.self) == 50)
            #expect(try config.get("server.port", as: Int.self) == 8080)
        }
    }

    @Test("unresolved substitution in the selected env file fails the load loudly")
    func unresolvedSubstitutionFailsLoad() throws {
        let prodYAML = "datasource:\n  url: ${ALULA_DATASOURCE_URL}"
        try withConfigDirectory(files: ["alula.yaml": baseYAML, "alula-prod.yaml": prodYAML]) { directory in
            // ALULA_DATASOURCE_URL deliberately unset: silently falling back
            // to the base (dev) URL is the failure this must never allow.
            #expect(throws: ConfigLoadError.self) {
                _ = try Configuration.load(
                    from: directory,
                    processEnvironment: ["ALULA_ENV": "prod"]
                )
            }
        }
    }

    @Test("an unselected environment's file is never parsed")
    func unselectedFilesIgnored() throws {
        try withConfigDirectory(files: [
            "alula.yaml": baseYAML,
            // Would fail parsing AND substitution — but dev doesn't read it.
            "alula-prod.yaml": "broken: [flow, ${UNSET_VAR}",
        ]) { directory in
            let config = try Configuration.load(from: directory, processEnvironment: [:])
            #expect(try config.get("server.port", as: Int.self) == 8080)
        }
    }

    @Test("a syntactically invalid base file fails with file, line, and message")
    func invalidBaseFile() throws {
        try withConfigDirectory(files: ["alula.yaml": "a: 1\nb: {flow: style}"]) { directory in
            do {
                _ = try Configuration.load(from: directory, processEnvironment: [:])
                Issue.record("expected parseFailed")
            } catch let error as ConfigLoadError {
                guard case .parseFailed(let file, let line, _, let message) = error else {
                    Issue.record("wrong case: \(error)")
                    return
                }
                #expect(file == "alula.yaml")
                #expect(line == 2)
                #expect(message.contains("flow style"))
            }
        }
    }

    @Test("missing keys after a real load report the active environment")
    func missingKeyCarriesEnvironment() throws {
        try withConfigDirectory(files: ["alula.yaml": baseYAML]) { directory in
            let config = try Configuration.load(
                from: directory,
                processEnvironment: ["ALULA_ENV": "staging"]
            )
            do {
                _ = try config.get("secrets.api_key", as: String.self)
                Issue.record("expected missingKey")
            } catch let error as ConfigError {
                #expect("\(error)".contains("staging"))
                #expect("\(error)".contains("ALULA_SECRETS_API_KEY"))
            }
        }
    }

    @Test("test is a first-class environment with its own file")
    func testEnvironmentFile() throws {
        let testYAML = "datasource:\n  url: \"postgres://localhost:5432/alula_test\""
        try withConfigDirectory(files: ["alula.yaml": baseYAML, "alula-test.yaml": testYAML]) { directory in
            let config = try Configuration.load(
                from: directory,
                processEnvironment: ["ALULA_ENV": "test"]
            )
            #expect(try config.get("datasource.url", as: String.self) == "postgres://localhost:5432/alula_test")
            #expect(try config.get("datasource.pool_size", as: Int.self) == 5)
        }
    }
}
