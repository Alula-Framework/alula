import Logging
import ServiceLifecycle
import Testing

@testable import AlulaCore

@Suite("The report on exit says what ended the application")
struct ExitReportTests {
    struct Broke: Error, CustomStringConvertible {
        var description: String { "the provider feed closed" }
    }

    /// Runs for `after`, then throws, returns, or waits for shutdown.
    struct Timed: Service {
        enum Then { case fail, returnEarly }
        let after: Duration
        let then: Then
        func run() async throws {
            try await Task.sleep(for: after)
            switch then {
            case .fail: throw Broke()
            case .returnEarly: return
            }
        }
    }

    struct Steady: Service {
        func run() async throws { try? await gracefulShutdown() }
    }

    struct FeedModule: AlulaModule {
        var after: Duration
        var then: Timed.Then
        var service: (any Service)? { Timed(after: after, then: then) }
    }

    struct ServerModule: AlulaModule {
        var service: (any Service)? { Steady() }
    }

    private func report(_ modules: [any AlulaModule]) async -> String {
        do {
            try await _alulaBootstrap(configuration: Configuration(), moduleInstances: modules)
            return "no error"
        } catch {
            return failureReport(for: error, detail: nil)
        }
    }

    @Test("a module failing after the application started is not 'could not start'")
    func failureWhileRunning() async {
        let text = await report([
            ServerModule(), FeedModule(after: .milliseconds(1300), then: .fail),
        ])
        #expect(text.hasPrefix("alula: stopped after running 1s: FeedModule failed.\n"), "\(text)")
        #expect(text.contains("error: [ALU-LIFE-8005] FeedModule failed after running 1s"))
        #expect(text.contains("    the provider feed closed"))
        #expect(!text.contains("could not start"))
    }

    @Test("a failure in the first moments is still a failed start")
    func failureDuringStart() async {
        let text = await report([ServerModule(), FeedModule(after: .milliseconds(10), then: .fail)])
        #expect(text.hasPrefix("alula: could not start.\n"), "\(text)")
    }

    @Test("a service that returns while the application runs is named")
    func endedOnItsOwn() async {
        let text = await report([
            ServerModule(), FeedModule(after: .milliseconds(1300), then: .returnEarly),
        ])
        #expect(
            text.hasPrefix(
                "alula: stopped after running 1s: FeedModule's service ended on its own."),
            "\(text)")
        #expect(text.contains("error: [ALU-LIFE-8006] FeedModule's service returned without throwing"))
        #expect(text.contains("serviceCompletion: .endsApp"))
    }

    @Test("a service that returns at once is a failed start that names it")
    func endedOnItsOwnAtStart() async {
        let text = await report([ServerModule(), FeedModule(after: .zero, then: .returnEarly)])
        #expect(
            text.hasPrefix("alula: could not start: FeedModule's service ended on its own."),
            "\(text)")
        #expect(text.contains("[ALU-LIFE-8006]"))
    }

    @Test("uptime reads in the units that matter")
    func uptimeFormat() {
        #expect(formatUptime(.milliseconds(850)) == "850 ms")
        #expect(formatUptime(.seconds(42)) == "42s")
        #expect(formatUptime(.seconds(247)) == "4m 07s")
        #expect(formatUptime(.seconds(3 * 3600 + 5 * 60)) == "3h 5m")
        #expect(formatUptime(.seconds(3 * 86_400 + 4 * 3600 + 12 * 60)) == "3d 4h 12m")
    }
}
