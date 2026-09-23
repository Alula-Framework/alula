import Foundation
import Testing
@testable import AlulaConfig

/// A deployment carrying Flight-era spellings is refused rather than read
/// without them (D45): an unset `ALULA_ENV` means `dev`, so reading on would
/// start a production deploy with dev settings.
@Suite("Configuration.load refuses pre-rename configuration")
struct PreRenameConfigurationTests {
    private func withDirectory<T>(_ names: [String], _ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alula-prerename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in names {
            try "server:\n  port: 8080\n".write(
                to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return try body(directory)
    }

    @Test func flightEnvironmentIsRefusedAndEveryFlightVariableNamed() throws {
        try withDirectory(["alula.yaml"]) { directory in
            #expect(
                throws: ConfigLoadError.preRenameConfiguration(
                    variables: ["FLIGHT_DATASOURCE_URL", "FLIGHT_ENV"], files: [])
            ) {
                try Configuration.load(
                    from: directory,
                    processEnvironment: [
                        "FLIGHT_ENV": "prod", "FLIGHT_DATASOURCE_URL": "postgres://db/x",
                    ])
            }
        }
    }

    @Test func aFlightOverlayBesideARenamedBaseIsRefused() throws {
        try withDirectory(["alula.yaml", "flight-prod.yaml"]) { directory in
            #expect(
                throws: ConfigLoadError.preRenameConfiguration(
                    variables: [], files: ["flight-prod.yaml"])
            ) {
                try Configuration.load(from: directory, processEnvironment: ["ALULA_ENV": "prod"])
            }
        }
    }

    @Test func aMovedDeploymentLoads() throws {
        try withDirectory(["alula.yaml"]) { directory in
            // ALULA_ENV says the deployment has moved; an unrelated FLIGHT_
            // variable, or one alone, is the application's own business.
            let moved = try Configuration.load(
                from: directory, processEnvironment: ["ALULA_ENV": "prod", "FLIGHT_ENV": "prod"])
            #expect(moved.environment == .prod)
            _ = try Configuration.load(
                from: directory, processEnvironment: ["FLIGHT_NUMBER": "BA117"])
        }
    }

    @Test func theOldPrefixStillWorksWhenAskedFor() throws {
        try withDirectory(["flight.yaml"]) { directory in
            let config = try Configuration.load(
                from: directory, prefix: ConfigPrefix("flight"),
                processEnvironment: ["FLIGHT_ENV": "prod", "FLIGHT_SERVER_PORT": "9000"])
            #expect(config.environment == .prod)
            #expect(try config.get("server.port", as: Int.self) == 9000)
        }
    }
}
