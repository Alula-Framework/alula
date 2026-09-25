import AlulaCore
import AlulaSessions
import AlulaSessionsTesting
import AlulaWebTesting
import Foundation
import HTTPTypes
import Testing

@testable import AlulaWeb

@Controller("/")
private struct CSRFTestController {
    @GetRoute("/form")
    func form(_ context: RequestContext) throws -> String {
        try context.requireSession().csrfToken()
    }

    @PostRoute("/transfer")
    func transfer(_ context: RequestContext) throws -> String {
        "done"
    }

    @DeleteRoute("/thing")
    func delete(_ context: RequestContext) throws -> String {
        "deleted"
    }
}

@Suite("CSRFToken")
struct CSRFTokenTests {

    @Test("a generated token is 43 characters of unpadded base64url, like a session id")
    func shape() {
        let token = CSRFToken.generate()
        #expect(token.count == 43)
        #expect(!token.contains("=") && !token.contains("+") && !token.contains("/"))
    }

    @Test("two generated tokens differ")
    func distinct() {
        let tokens = Set((0..<32).map { _ in CSRFToken.generate() })
        #expect(tokens.count == 32)
    }

    @Test("matches is true only for the identical string")
    func matching() {
        let token = CSRFToken.generate()
        #expect(CSRFToken.matches(token, token))
        #expect(!CSRFToken.matches(token, CSRFToken.generate()))
    }

    @Test("matches rejects a mismatched length rather than comparing a prefix")
    func lengthMismatch() {
        #expect(!CSRFToken.matches("short", "shorter-still"))
        #expect(!CSRFToken.matches("", CSRFToken.generate()))
    }

    @Test("Session.csrfToken() is stable across reads and generated once")
    func sessionTokenIsStable() throws {
        let session = Session()
        let first = try session.csrfToken()
        let second = try session.csrfToken()
        #expect(first == second)
    }

    @Test("a session loaded from a stored record keeps the same token")
    func tokenSurvivesReload() throws {
        let original = Session()
        let token = try original.csrfToken()
        guard case .save(_, let record, _) = original.commit(now: Date(), ttl: .seconds(60)) else {
            Issue.record("expected a save")
            return
        }
        let reloaded = Session(id: SessionID.generate(), record: record)
        #expect(try reloaded.csrfToken() == token)
    }
}

@Suite("CSRFProtection")
struct CSRFProtectionTests {
    private let store = RecordingSessionStore()

    private func client() throws -> TestClient {
        let sessions = try AlulaSessionsModule(
            configuration: Configuration(values: ["sessions.cookie-secure": "false"]),
            store: store)
        return try TestClient(
            routes: CSRFTestController.alulaRoutes { _ in CSRFTestController() },
            middleware: sessions.middleware
                + MiddlewareRegistration.lane(.default, [CSRFProtection()]))
    }

    private func sessionCookie(_ response: Response) -> String? {
        response.headerValues("Set-Cookie")
            .compactMap { $0.split(separator: ";").first.map(String.init) }
            .first { $0.hasPrefix("session=") }
    }

    // MARK: Safe methods

    @Test("a GET is never checked, even with no token anywhere")
    func safeMethodsPassThrough() async throws {
        let response = await (try client()).get("/form")
        #expect(response.status == .ok)
    }

    // MARK: Unsafe methods, no token

    @Test("a POST with no token at all is refused")
    func missingTokenRefused() async throws {
        let client = try client()
        let form = await client.get("/form")
        let cookie = try #require(sessionCookie(form))
        let response = await client.post("/transfer", headers: [.cookie: cookie])
        #expect(response.status == .forbidden)
    }

    @Test("a POST with the wrong token is refused")
    func wrongTokenRefused() async throws {
        let client = try client()
        let form = await client.get("/form")
        let cookie = try #require(sessionCookie(form))
        let response = await client.post(
            "/transfer", headers: [.cookie: cookie, .xCSRFToken: "not-the-real-token"])
        #expect(response.status == .forbidden)
    }

    // MARK: Bearer tokens

    @Test("a bearer-token POST is not checked, session or not: nothing ambient to forge")
    func bearerRequestsPass() async throws {
        let client = try client()
        let bare = await client.post("/transfer", headers: [.authorization: "Bearer rk_key"])
        #expect(bare.status == .ok)
        // A cookie beside it changes nothing: the header was set by the
        // caller, which a page on another site cannot do.
        let form = await client.get("/form")
        let cookie = try #require(sessionCookie(form))
        let withCookie = await client.post(
            "/transfer", headers: [.cookie: cookie, .authorization: "bearer rk_key"])
        #expect(withCookie.status == .ok)
    }

    @Test("Basic credentials are still checked: browsers replay them on their own")
    func basicIsNotExempt() async throws {
        let response = await (try client()).post(
            "/transfer", headers: [.authorization: "Basic YWRhOnB3"])
        #expect(response.status == .forbidden)
        let empty = await (try client()).post("/transfer", headers: [.authorization: "Bearer "])
        #expect(empty.status == .forbidden)
    }

    // MARK: The real round trip

    @Test("the token a GET hands out is accepted on the POST that follows")
    func correctTokenAccepted() async throws {
        let client = try client()
        let form = await client.get("/form")
        let cookie = try #require(sessionCookie(form))
        let token = form.bodyText

        let response = await client.post(
            "/transfer", headers: [.cookie: cookie, .xCSRFToken: token])
        #expect(response.status == .ok)
        #expect(response.bodyText == "done")
    }

    @Test("every unsafe method is checked, not only POST")
    func everyUnsafeMethodChecked() async throws {
        let client = try client()
        let form = await client.get("/form")
        let cookie = try #require(sessionCookie(form))
        let token = form.bodyText

        #expect(await client.delete("/thing", headers: [.cookie: cookie]).status == .forbidden)
        #expect(
            await client.delete("/thing", headers: [.cookie: cookie, .xCSRFToken: token])
                .status == .ok)
    }

    @Test("the token is stable across requests, the way a page kept open needs it to be")
    func tokenStableAcrossRequests() async throws {
        let client = try client()
        let form = await client.get("/form")
        let cookie = try #require(sessionCookie(form))
        let token = form.bodyText

        let again = await client.get("/form", headers: [.cookie: cookie])
        #expect(again.bodyText == token)
    }

    // MARK: No session in the lane at all

    @Test("with no Sessions middleware, an unsafe request is left alone entirely")
    func noSessionPassesThrough() async throws {
        // A bearer-token-only lane: CSRF cannot apply to ambient authority
        // that does not exist, and this must not force every such route
        // to carry Sessions just to compose.
        let client = try TestClient(
            routes: CSRFTestController.alulaRoutes { _ in CSRFTestController() },
            middleware: MiddlewareRegistration.lane(.default, [CSRFProtection()]))
        let response = await client.post("/transfer")
        #expect(response.status == .ok)
    }

    // MARK: Composition ordering

    @Test("CSRFProtection listed ahead of Sessions fails composition, naming the route")
    func orderingIsChecked() throws {
        let sessions = try AlulaSessionsModule(configuration: Configuration(), store: store)
        #expect(throws: DispatchBuilder.SessionOrderError.self) {
            try TestClient(
                routes: CSRFTestController.alulaRoutes { _ in CSRFTestController() },
                middleware: MiddlewareRegistration.lane(.default, [CSRFProtection()])
                    + sessions.middleware)
        }
    }
}
