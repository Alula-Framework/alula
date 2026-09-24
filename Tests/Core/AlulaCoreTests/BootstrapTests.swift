import Testing

@testable import AlulaCore

@Suite("Bootstrap sequence and module health")
struct BootstrapTests {

    @Test("assemble collects services in the given order, cross-module values wired")
    func happyPath() throws {
        let logging = LoggingModule()
        let app = try Alula.assemble(
            configuration: Configuration(values: ["alula.test": "1"]),
            modules: [logging, FakeServerModule(sink: logging.sink)]
        )
        #expect(app.moduleOrder == ["LoggingModule", "FakeServerModule"])
        #expect(app.services.count == 1)
        #expect(app.services.first?.moduleName == "FakeServerModule")
    }

    @Test("a service-less module is running at assembly; a service owner waits for its service")
    func healthAfterAssembly() async throws {
        let logging = LoggingModule()
        let app = try Alula.assemble(
            configuration: Configuration(),
            modules: [logging, FakeServerModule(sink: logging.sink)])
        func health(_ name: String) -> ModuleHealth? {
            app.health.statuses().first { $0.moduleName == name }?.health
        }
        #expect(app.health.statuses().count == 2)
        #expect(health("LoggingModule") == .running)
        // Reporting it running here made readiness answer yes before
        // anything had started.
        #expect(health("FakeServerModule") == .notStarted)

        let entry = try #require(app.services.first)
        let running = Task { try await entry.service.run() }
        defer { running.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while health("FakeServerModule") != .running, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(health("FakeServerModule") == .running)
    }

    @Test("a failing Service flips its module to .failed")
    func serviceFailureHealth() async throws {
        let app = try Alula.assemble(
            configuration: Configuration(), modules: [FailingServiceModule()])
        let entry = try #require(app.services.first)

        await #expect(throws: TestServiceError.self) {
            try await entry.service.run()
        }

        let status = try #require(
            app.health.statuses().first { $0.moduleName == "FailingServiceModule" }
        )
        guard case .failed = status.health else {
            Issue.record("expected .failed, got \(status.health)")
            return
        }
    }

    @Test("bootstrap returns immediately when no module owns a service")
    func serviceLessBootstrap() async throws {
        // Valid shape for one-shot CLI-style Alula apps.
        try await Alula.bootstrap(configuration: Configuration(), modules: [LoggingModule()])
    }

    @Test("a .endsApp service finishing shuts the app down gracefully")
    func oneShotServiceBootstrap() async throws {
        // Default (.failsApp) would make bootstrap throw serviceFinishedUnexpectedly here.
        try await Alula.bootstrap(configuration: Configuration(), modules: [OneShotModule()])
    }
}
