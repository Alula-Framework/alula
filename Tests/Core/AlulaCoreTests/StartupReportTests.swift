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
}
