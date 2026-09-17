import Foundation
import Testing

@testable import FlightConfig

/// One word, four spellings. These assert they stay derived from it rather
/// than drifting apart — the whole reason the type exists.
@Suite("ConfigPrefix")
struct ConfigPrefixTests {

    @Test("the default reproduces every spelling Flight shipped before the type")
    func defaultMatchesHistoricalSpellings() {
        let prefix = ConfigPrefix.default
        #expect(prefix.baseFileName == "flight.yaml")
        #expect(prefix.environmentFileName(for: .prod) == "flight-prod.yaml")
        #expect(prefix.environmentVariable == "FLIGHT_ENV")
        #expect(prefix.variableName(for: "datasource.url") == "FLIGHT_DATASOURCE_URL")
        #expect(prefix.variableName(for: "datasource.pool_size") == "FLIGHT_DATASOURCE_POOL_SIZE")
    }

    @Test("a custom prefix moves all four spellings together")
    func customPrefixDerivesEverything() {
        let prefix = ConfigPrefix("myapp")
        #expect(prefix.baseFileName == "myapp.yaml")
        #expect(prefix.environmentFileName(for: .staging) == "myapp-staging.yaml")
        #expect(prefix.environmentVariable == "MYAPP_ENV")
        #expect(prefix.variableName(for: "server.port") == "MYAPP_SERVER_PORT")
    }

    @Test("FlightConfigFiles still agrees with the default prefix by construction")
    func filesAgreeWithDefault() {
        #expect(FlightConfigFiles.base == ConfigPrefix.default.baseFileName)
        #expect(
            FlightConfigFiles.environmentFile(for: .test)
                == ConfigPrefix.default.environmentFileName(for: .test))
    }

    @Test("validating: reports a bad prefix instead of trapping")
    func validatingRejectsUnusableNames() {
        // The build tool reads prefixes out of an application's source, where a
        // bad value is the author's typo — trapping there would crash codegen
        // rather than point at the line.
        #expect(ConfigPrefix(validating: "myapp") != nil)
        #expect(ConfigPrefix(validating: "svc_2") != nil)
        #expect(ConfigPrefix(validating: "my-app") == nil, "a dash cannot be set in a shell")
        #expect(ConfigPrefix(validating: "2fast") == nil, "a leading digit is not a variable name")
        #expect(ConfigPrefix(validating: "MyApp") == nil, "uppercase would double-uppercase")
        #expect(ConfigPrefix(validating: "") == nil)
        #expect(ConfigPrefix(validating: "my.app") == nil)
    }

    @Test("a validated prefix derives the same names as the trapping initializer")
    func validatingMatchesInit() {
        let validated = try! #require(ConfigPrefix(validating: "myapp"))
        #expect(validated == ConfigPrefix("myapp"))
        #expect(validated.baseFileName == "myapp.yaml")
    }

    @Test("a prefix is writable as a plain string literal")
    func stringLiteral() {
        let prefix: ConfigPrefix = "svc2"
        #expect(prefix.variableName(for: "a.b") == "SVC2_A_B")
    }
}

/// `Configuration.load` under a non-default prefix: files, environment
/// selection, and the env-var layer must all move together. A prefix that
/// moved only some of them would read one file while honouring another
/// namespace's variables.
@Suite("Configuration.load(prefix:)")
struct ConfigurationLoadPrefixTests {

    private func withConfigDirectory<T>(
        files: [String: String],
        _ body: (URL) throws -> T
    ) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flight-prefix-tests-\(UUID().uuidString)")
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
        server:
          port: 8080
        """

    @Test("the base file is read under the custom name")
    func customBaseFileName() throws {
        try withConfigDirectory(files: ["myapp.yaml": baseYAML]) { directory in
            let config = try Configuration.load(
                from: directory, prefix: "myapp", processEnvironment: [:])
            #expect(try config.get("server.port", as: Int.self) == 8080)
        }
    }

    @Test("flight.yaml is not consulted under a custom prefix")
    func defaultNameIsNotAFallback() throws {
        // Falling back to flight.yaml would make the prefix advisory, and an
        // app could silently run on a file it thought it had renamed away.
        try withConfigDirectory(files: ["flight.yaml": baseYAML]) { directory in
            #expect(throws: ConfigLoadError.self) {
                _ = try Configuration.load(
                    from: directory, prefix: "myapp", processEnvironment: [:])
            }
        }
    }

    @Test("<PREFIX>_ENV selects the overlay, and FLIGHT_ENV no longer does")
    func environmentVariableFollowsPrefix() throws {
        let prodYAML = "server:\n  port: 443"
        try withConfigDirectory(files: ["myapp.yaml": baseYAML, "myapp-prod.yaml": prodYAML]) {
            directory in
            let config = try Configuration.load(
                from: directory, prefix: "myapp",
                processEnvironment: ["MYAPP_ENV": "prod"])
            #expect(config.environment == .prod)
            #expect(try config.get("server.port", as: Int.self) == 443)

            // The old variable is just another unset name now.
            let ignored = try Configuration.load(
                from: directory, prefix: "myapp",
                processEnvironment: ["FLIGHT_ENV": "prod"])
            #expect(ignored.environment == .dev)
            #expect(try ignored.get("server.port", as: Int.self) == 8080)
        }
    }

    @Test("the env-var layer reads <PREFIX>_ names and ignores FLIGHT_ ones")
    func environmentLayerFollowsPrefix() throws {
        try withConfigDirectory(files: ["myapp.yaml": baseYAML]) { directory in
            let config = try Configuration.load(
                from: directory, prefix: "myapp",
                processEnvironment: [
                    "MYAPP_SERVER_PORT": "9090",
                    "FLIGHT_SERVER_PORT": "1111",
                ])
            #expect(try config.get("server.port", as: Int.self) == 9090)
        }
    }

    @Test("a missing key names the variable that would actually satisfy it")
    func missingKeyNamesThePrefixedVariable() throws {
        try withConfigDirectory(files: ["myapp.yaml": baseYAML]) { directory in
            let config = try Configuration.load(
                from: directory, prefix: "myapp", processEnvironment: [:])
            do {
                _ = try config.get("secrets.api_key", as: String.self)
                Issue.record("expected missingKey")
            } catch let error as ConfigError {
                let message = "\(error)"
                #expect(message.contains("MYAPP_SECRETS_API_KEY"))
                #expect(message.contains("myapp.yaml"))
                #expect(!message.contains("FLIGHT_"))
            }
        }
    }

    @Test("the missing-base-file error names the custom file and the from: escape hatch")
    func missingBaseFileMessage() throws {
        try withConfigDirectory(files: [:]) { directory in
            do {
                _ = try Configuration.load(
                    from: directory, prefix: "myapp", processEnvironment: [:])
                Issue.record("expected missingBaseFile")
            } catch let error as ConfigLoadError {
                let message = "\(error)"
                #expect(message.contains("myapp.yaml"))
                #expect(message.contains("myapp-{env}.yaml"))
                #expect(message.contains("Configuration.load(from:)"))
            }
        }
    }
}
