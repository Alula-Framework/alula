import AlulaCore
import AlulaWebTesting
import Foundation
import Testing

@testable import AlulaTransport

@Suite("A server that cannot listen says where and why")
struct ListenFailureTests {
    @Test("a port already in use is named, with the settings that choose it")
    func addressInUse() async throws {
        // Relay: `alula: could not start.` over
        // `bind(descriptor:ptr:bytes:): Address already in use) (errno: 98)`,
        // naming no address.
        try await withRunningServer { port in
            let dispatch = try TestClient(routes: wireRoutes()).dispatch
            let second = AlulaTransport(
                configuration: AlulaTransportConfiguration(host: "127.0.0.1", port: port),
                dispatch: dispatch)
            do {
                try await second.run()
                Issue.record("a second server bound a port already in use")
            } catch let failure as any StartupDiagnostic {
                let text = failure.startupDiagnostic
                #expect(text.hasPrefix("could not listen on 127.0.0.1:\(port): the address is already in use"))
                #expect(text.contains("server.port"))
            }
        }
    }
}
