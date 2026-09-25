import Testing

@testable import AlulaCore

@Suite("Startup error report")
struct StartupReportTests {
    /// Shaped like PSQLError: `description` redacted on purpose, and a
    /// `debugDescription` (what reflection prints) with the connection URL,
    /// password included.
    struct ConnectFailed: Error, CustomStringConvertible, CustomDebugStringConvertible {
        let url = "postgres://app:hunter2@db.internal:5432/app"
        var description: String { "could not connect to the database" }
        var debugDescription: String { "ConnectFailed(url: \(url))" }
    }

    struct PoolDown: Error, StartupDiagnostic {
        var startupDiagnostic: String {
            "could not connect to db.internal:5432: connection refused"
        }
    }

    @Test("an error's own description is printed, never its reflected contents")
    func redacted() {
        let report = startupReport(for: ConnectFailed(), detail: nil)
        #expect(report == "could not connect to the database")
        #expect(!report.contains("hunter2"))
    }

    @Test("a StartupDiagnostic says what it chose to")
    func diagnostic() {
        #expect(
            startupReport(for: PoolDown(), detail: nil)
                == "could not connect to db.internal:5432: connection refused")
    }

    @Test("reflection only when explicitly asked for")
    func optIn() {
        #expect(startupReport(for: ConnectFailed(), detail: "reflect").contains("hunter2"))
        #expect(!startupReport(for: ConnectFailed(), detail: "1").contains("hunter2"))
    }

    /// A framework-owned failure carries its code and page; one the
    /// application owns prints as it always did.
    @Test("configuration failures at startup carry their codes")
    func configurationCodes() {
        func report(_ error: any Error) -> String { failureReport(for: error, detail: nil) }
        #expect(report(ConfigError.missingKey(key: "mail.host", environment: .prod)).contains("error: [ALU-CONFIG-5004] Configuration key 'mail.host'"))
        #expect(report(ConfigError.decodingFailed(key: "server.port", rawValue: "eighty", targetType: "Int")).contains("[ALU-CONFIG-5008]"))
        #expect(report(ConfigError.providerFailed(key: "db.password", provider: "vault", reason: "timed out")).contains("[ALU-CONFIG-5009]"))
        #expect(report(ConfigLoadError.missingBaseFile(expectedPath: "/srv/app/alula.yaml")).contains("[ALU-CONFIG-5010]"))
        #expect(report(ConfigLoadError.parseFailed(file: "alula.yaml", line: 3, column: 4, message: "bad")).contains("[ALU-CONFIG-5007]"))
        #expect(report(ConfigLoadError.unresolvedSubstitution(file: "alula.yaml", line: 2, key: "db.url", variable: "DB_URL")).contains("[ALU-CONFIG-5011]"))
        #expect(report(ConfigLoadError.preRenameConfiguration(variables: ["FLIGHT_ENV"], files: [])).contains("[ALU-CONFIG-5012]"))
        let coded = report(ConfigError.missingKey(key: "mail.host", environment: nil))
        #expect(coded.hasPrefix("alula: could not start.\nerror: [ALU-CONFIG-5004]"))
        #expect(coded.contains("docs: https://"))
        #expect(report(PoolDown()) == "alula: could not start.\ncould not connect to db.internal:5432: connection refused\n")
    }
}
