import AlulaCore
import AlulaWeb
import AlulaWebTesting
import Foundation
import HTTPTypes
import Testing

@Controller("/api")
private struct CORSTestController {
    @GetRoute("/items")
    func items(_ context: RequestContext) async throws -> String { "items" }

    @PostRoute("/items")
    func create(_ context: RequestContext) async throws -> String { "created" }

    @GetRoute("/boom")
    func boom(_ context: RequestContext) async throws -> String {
        throw HTTPError(.internalServerError, "boom")
    }

    /// Sets its own `Vary`, so the middleware has something to preserve.
    @GetRoute("/negotiated")
    func negotiated(_ context: RequestContext) async throws -> Response {
        Response.text("negotiated").settingHeader(.vary, "Accept-Encoding")
    }
}

@Suite("CORS")
struct CORSTests {

    private func client(_ cors: CORS) throws -> TestClient {
        try TestClient(
            routes: CORSTestController.alulaRoutes { _ in CORSTestController() },
            middleware: MiddlewareRegistration.lane(.default, [cors]))
    }

    private var strict: CORS {
        CORS(
            allowedOrigins: .exact(["https://app.example.com"]),
            allowedMethods: [.get, .post],
            allowedHeaders: .exact([.contentType, .authorization]),
            exposedHeaders: [.eTag],
            allowCredentials: true,
            maxAge: .seconds(600))
    }

    // MARK: Ordinary requests

    @Test("a request with no Origin is left entirely alone")
    func noOriginIsUntouched() async throws {
        let response = await (try client(strict)).get("/api/items")
        #expect(response.status == .ok)
        #expect(response.headers[.accessControlAllowOrigin] == nil)
        #expect(response.headers[.vary] == nil)
    }

    @Test("an allowed origin is echoed, with Vary so caches stay honest")
    func allowedOriginIsEchoed() async throws {
        let response = await (try client(strict)).get(
            "/api/items", headers: [.origin: "https://app.example.com"])
        #expect(response.status == .ok)
        #expect(response.headers[.accessControlAllowOrigin] == "https://app.example.com")
        #expect(response.headers[.accessControlAllowCredentials] == "true")
        #expect(response.headers[.accessControlExposeHeaders] == "etag")
        #expect(response.headers[.vary]?.lowercased().contains("origin") == true)
    }

    @Test("a disallowed origin gets no allow header — and the Vary anyway")
    func disallowedOriginGetsNoHeader() async throws {
        let response = await (try client(strict)).get(
            "/api/items", headers: [.origin: "https://evil.example.com"])
        // The handler ran: CORS governs who may read an answer, not who may
        // ask. The browser is what withholds it.
        #expect(response.status == .ok)
        #expect(response.headers[.accessControlAllowOrigin] == nil)
        // Load-bearing: without this a shared cache can serve the allowed
        // origin's response — headers and all — to this one.
        #expect(response.headers[.vary]?.lowercased().contains("origin") == true)
    }

    @Test("wildcard answers a literal star and needs no Vary")
    func wildcardIsConstant() async throws {
        let open = CORS(allowedOrigins: .any, allowedMethods: [.get])
        let response = await (try client(open)).get(
            "/api/items", headers: [.origin: "https://anywhere.example"])
        #expect(response.headers[.accessControlAllowOrigin] == "*")
        #expect(response.headers[.vary] == nil)
    }

    @Test("a predicate decides per request")
    func predicateOrigins() async throws {
        let cors = CORS(
            allowedOrigins: .matching { $0.hasPrefix("https://") && $0.hasSuffix(".example.com") },
            allowedMethods: [.get])
        let client = try client(cors)
        let ok = await client.get("/api/items", headers: [.origin: "https://a.example.com"])
        let insecure = await client.get("/api/items", headers: [.origin: "http://a.example.com"])
        #expect(ok.headers[.accessControlAllowOrigin] == "https://a.example.com")
        #expect(insecure.headers[.accessControlAllowOrigin] == nil)
    }

    @Test("headers are added to error responses too")
    func errorsCarryTheHeaders() async throws {
        let response = await (try client(strict)).get(
            "/api/boom", headers: [.origin: "https://app.example.com"])
        // A 500 a page cannot read is a 500 nobody can debug.
        #expect(response.status == .internalServerError)
        #expect(response.headers[.accessControlAllowOrigin] == "https://app.example.com")
    }

    @Test("an existing Vary is appended to, never replaced")
    func varyIsAppended() async throws {
        let response = await (try client(strict)).get(
            "/api/negotiated", headers: [.origin: "https://app.example.com"])
        let vary = try #require(response.headers[.vary]).lowercased()
        #expect(vary.contains("accept-encoding"))
        #expect(vary.contains("origin"))
    }

    @Test("Vary does not accumulate duplicates")
    func varyDoesNotDuplicate() async throws {
        // Two CORS layers in one lane is a misconfiguration, but it is the
        // shape that grows an unbounded header in production.
        let client = try TestClient(
            routes: CORSTestController.alulaRoutes { _ in CORSTestController() },
            middleware: MiddlewareRegistration.lane(.default, [strict, strict]))
        let response = await client.get(
            "/api/items", headers: [.origin: "https://app.example.com"])
        let vary = try #require(response.headers[.vary]).lowercased()
        #expect(vary.components(separatedBy: "origin").count - 1 == 1)
    }

    // MARK: Preflight

    @Test("a preflight is answered here and never reaches the route")
    func preflightIsAnswered() async throws {
        let response = await (try client(strict)).execute(
            Request(
                method: .options, path: "/api/items",
                headers: [
                    .origin: "https://app.example.com",
                    .accessControlRequestMethod: "POST",
                ]))
        #expect(response.status == .noContent)
        #expect(response.headers[.accessControlAllowOrigin] == "https://app.example.com")
        #expect(response.headers[.accessControlAllowMethods] == "GET, POST")
        #expect(response.headers[.accessControlAllowHeaders] == "content-type, authorization")
        #expect(response.headers[.accessControlMaxAge] == "600")
        #expect(response.headers[.accessControlAllowCredentials] == "true")
    }

    @Test("a preflight varies on all three request headers")
    func preflightVaries() async throws {
        let response = await (try client(strict)).execute(
            Request(
                method: .options, path: "/api/items",
                headers: [
                    .origin: "https://app.example.com",
                    .accessControlRequestMethod: "GET",
                ]))
        let vary = try #require(response.headers[.vary]).lowercased()
        #expect(vary.contains("origin"))
        #expect(vary.contains("access-control-request-method"))
        #expect(vary.contains("access-control-request-headers"))
    }

    @Test("reflectingRequest echoes exactly what was asked for")
    func reflectedHeaders() async throws {
        let cors = CORS(
            allowedOrigins: .exact(["https://app.example.com"]),
            allowedMethods: [.get], allowedHeaders: .reflectingRequest)
        let response = await (try client(cors)).execute(
            Request(
                method: .options, path: "/api/items",
                headers: [
                    .origin: "https://app.example.com",
                    .accessControlRequestMethod: "GET",
                    .accessControlRequestHeaders: "x-tenant, x-trace",
                ]))
        #expect(response.headers[.accessControlAllowHeaders] == "x-tenant, x-trace")
    }

    @Test("a preflight from a disallowed origin is refused, and says so")
    func preflightRefusesOrigin() async throws {
        let response = await (try client(strict)).execute(
            Request(
                method: .options, path: "/api/items",
                headers: [
                    .origin: "https://evil.example.com",
                    .accessControlRequestMethod: "GET",
                ]))
        #expect(response.status == .forbidden)
        #expect(response.headers[.accessControlAllowOrigin] == nil)
        // The refusal must vary too, or a cache reuses it for a good origin.
        #expect(response.headers[.vary]?.lowercased().contains("origin") == true)
        #expect(response.bodyText.contains("evil.example.com"))
    }

    @Test("a preflight for a method that is not allowed names the method")
    func preflightRefusesMethod() async throws {
        let response = await (try client(strict)).execute(
            Request(
                method: .options, path: "/api/items",
                headers: [
                    .origin: "https://app.example.com",
                    .accessControlRequestMethod: "DELETE",
                ]))
        #expect(response.status == .forbidden)
        #expect(response.bodyText.contains("DELETE"))
    }

    @Test("OPTIONS without a request-method header is not a preflight")
    func optionsAloneIsRouted() async throws {
        let response = await (try client(strict)).execute(
            Request(
                method: .options, path: "/api/items",
                headers: [.origin: "https://app.example.com"]))
        // Routed, and the router answers 405 with Allow — not swallowed as a
        // preflight and answered 204.
        #expect(response.status == .methodNotAllowed)
        #expect(response.headers[.allow] != nil)
    }

    @Test("a lane without CORS does not get the headers")
    func lanesAreIndependent() async throws {
        // The documented trap: routing happens before middleware, so a route
        // on another lane is not covered by a CORS in .default.
        let client = try TestClient(
            routes: CORSTestController.alulaRoutes { _ in CORSTestController() },
            middleware: MiddlewareRegistration.lane(.default, []))
        let response = await client.get(
            "/api/items", headers: [.origin: "https://app.example.com"])
        #expect(response.headers[.accessControlAllowOrigin] == nil)
    }
}
