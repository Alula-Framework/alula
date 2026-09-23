import AlulaCore
import AlulaSessions
import AlulaSessionsTesting
import AlulaWeb
import AlulaWebTesting
import Foundation
import Synchronization
import Testing

@Controller("/")
private struct SessionWireController {
    @PostRoute("/login")
    func login(_ context: RequestContext) throws -> String {
        let session = try context.requireSession()
        try session.set("user", "ada")
        session.regenerate()
        return "signed in"
    }

    @GetRoute("/whoami")
    func whoami(_ context: RequestContext) throws -> String {
        try context.requireSession().get("user", as: String.self) ?? "nobody"
    }
}

/// A session's cookie through a real socket and a real transport: the
/// in-process suite proves the middleware, this proves that `Set-Cookie`
/// leaves the process and `Cookie` comes back into it through Hummingbird.
@Suite("AlulaTransport session wire behavior", .serialized)
struct SessionWireTests {

    @Test("login sets a cookie the next request is recognised by")
    func cookieRoundTrip() async throws {
        let store = RecordingSessionStore()
        let runtime = SessionRuntime(
            store: store, settings: try SessionSettings(ttl: .seconds(600), cookieSecure: false))
        try await withRunningServer(
            routes: SessionWireController.alulaRoutes { _ in SessionWireController() },
            middleware: MiddlewareRegistration.lane(.default, [Sessions(runtime: runtime)])
        ) { port in
            let captured = Mutex<String?>(nil)
            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send(
                    "POST /login HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                )
                let response = try await session.readToEnd()
                #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
                let line = try #require(
                    response.split(separator: "\r\n").first {
                        $0.lowercased().hasPrefix("set-cookie:")
                    })
                #expect(line.contains("HttpOnly"))
                #expect(line.contains("SameSite=Lax"))
                // "set-cookie: session=<id>; Path=/; …" → "session=<id>"
                let pair = String(line.dropFirst("set-cookie:".count)).split(separator: ";")[0]
                    .trimmingCharacters(in: .whitespaces)
                captured.withLock { $0 = pair }
            }
            let cookie = try #require(captured.withLock { $0 })
            #expect(cookie.hasPrefix("session="))
            #expect(store.entryCount == 1)

            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send(
                    "GET /whoami HTTP/1.1\r\nHost: localhost\r\nCookie: \(cookie)\r\nConnection: close\r\n\r\n"
                )
                let response = try await session.readToEnd()
                #expect(response.hasSuffix("\r\n\r\nada"))
                #expect(
                    !response.lowercased().contains("set-cookie:"),
                    "an untouched session is not rewritten")
            }
        }
    }
}
