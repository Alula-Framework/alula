import AlulaTesting
import Foundation
import Testing

/// Compiles the umbrella in CI and pins what one `import AlulaTesting` brings:
/// if a re-export or its trait gate goes missing, this stops compiling.
@Suite struct UmbrellaTests {
    @Test func reExportsTheUngatedTestingModules() {
        _ = RecordingMailTransport()
        _ = RecordingAdapter()
        _ = InMemoryCluster()
        _ = QueueTestHarness.self
        _ = RecordingRateLimitStore()
        _ = TestSchedulerClock(now: Date(timeIntervalSince1970: 0))
        _ = RecordingSessionStore()
    }

    #if Web
    @Test func reExportsTheWebTestingModules() {
        _ = TestClient.self
        _ = InMemoryTransport.self
        _ = InMemoryChannelTransport.self
    }
    #endif

    #if HTTPClient
    @Test func reExportsHTTPClientTesting() {
        _ = StubHTTPTransport { _ in .init(status: .ok) }
    }
    #endif

    #if APNS
    @Test func reExportsAPNSTesting() {
        _ = RecordingAPNSTransport()
    }
    #endif
}
