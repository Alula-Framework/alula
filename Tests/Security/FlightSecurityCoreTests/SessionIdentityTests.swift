import FlightCore
import FlightSessions
import FlightSessionsTesting
import FlightWeb
import FlightWebTesting
import Foundation
import HTTPTypes
import Synchronization
import Testing

@testable import FlightSecurityCore

@Suite("Session-backed identity")
struct SessionIdentityTests {
    private let store = RecordingSessionStore()
    private let validator = StubValidator(principalsByToken: [
        "token-ada": testPrincipal(subject: "ada-by-token", roles: ["admin"])
    ])

    private var runtime: SessionRuntime {
        SessionRuntime(
            store: store, settings: try! SessionSettings(ttl: .seconds(3600), cookieSecure: false))
    }

    // MARK: Principal on a session

    @Test("a principal round-trips through a session without its claims")
    func principalCoding() throws {
        let principal = Principal(
            subject: "ada", issuer: "https://idp.example.com", roles: ["admin"], scopes: ["read"],
            claims: ["email": "ada@example.com"])
        let session = Session()
        try session.signIn(principal)
        let stored = try #require(try session.principal())
        #expect(stored.subject == "ada")
        #expect(stored.issuer == "https://idp.example.com")
        #expect(stored.roles == ["admin"])
        #expect(stored.scopes == ["read"])
        #expect(stored.claims.isEmpty, "claims are a fact about a token, not a session")
    }

    @Test(
        "signIn regenerates the id; signOut forgets the principal, keeps the rest, and regenerates again"
    )
    func signInAndOut() throws {
        let planted = SessionID.generate()
        let session = Session(
            id: planted,
            record: SessionRecord(
                values: ["cart": Data("[]".utf8)], createdAt: Date(),
                expiresAt: Date().addingTimeInterval(3600)))
        try session.signIn(testPrincipal(subject: "ada"))
        guard
            case .save(let signedIn, let record, let replacing) = session.commit(
                now: Date(), ttl: .seconds(3600))
        else {
            Issue.record("expected a save")
            return
        }
        #expect(signedIn != planted, "fixation: the planted id is not the one signed in")
        #expect(replacing == planted)
        #expect(record.values["cart"] != nil, "values survive sign-in")
        #expect(record.values[Session.principalKey] != nil)

        let next = Session(id: signedIn, record: record)
        next.signOut()
        #expect(try next.principal() == nil)
        guard
            case .save(let after, let afterRecord, _) = next.commit(
                now: Date(), ttl: .seconds(3600))
        else {
            Issue.record("expected a save")
            return
        }
        #expect(after != signedIn)
        #expect(afterRecord.values["cart"] != nil)
        #expect(afterRecord.values[Session.principalKey] == nil)
    }

    // MARK: Authentication reads it

    /// Runs `Authentication` over `context` and returns what reached the
    /// handler.
    private func downstream(_ context: RequestContext) async throws -> RequestContext? {
        let captured = Mutex<RequestContext?>(nil)
        _ = try await Authentication(validator: validator).handle(context) { downstream in
            captured.withLock { $0 = downstream }
            return .status(.noContent)
        }
        return captured.withLock { $0 }
    }

    private func sessionSignedIn(as subject: String) throws -> Session {
        let session = Session()
        try session.signIn(testPrincipal(subject: subject, roles: ["member"]))
        return session
    }

    @Test("no token, a signed-in session: authenticated from the session")
    func sessionAuthenticates() async throws {
        let context = RequestContext.mock(session: try sessionSignedIn(as: "ada-by-session"))
        let handled = try #require(try await downstream(context))
        #expect(handled.principal?.subject == "ada-by-session")
        #expect(handled.principal?.hasRole("member") == true)
        #expect(handled.logger[metadataKey: "auth.subject"] == "ada-by-session")
    }

    @Test("a bearer token wins over the session")
    func tokenWins() async throws {
        let context = RequestContext.mock(
            headers: [.authorization: "Bearer token-ada"],
            session: try sessionSignedIn(as: "ada-by-session"))
        let handled = try #require(try await downstream(context))
        #expect(handled.principal?.subject == "ada-by-token")
    }

    @Test("a session with nobody signed in is anonymous")
    func emptySession() async throws {
        let handled = try #require(try await downstream(.mock(session: Session())))
        #expect(handled.principal == nil)
        #expect(handled.authenticationState.principal == nil)
    }

    @Test("a stored principal that does not decode is anonymous, not a 500")
    func undecodableStoredPrincipal() async throws {
        let session = Session(
            id: SessionID.generate(),
            record: SessionRecord(
                values: [Session.principalKey: Data("42".utf8)], createdAt: Date(),
                expiresAt: Date().addingTimeInterval(60)))
        let handled = try #require(try await downstream(.mock(session: session)))
        #expect(handled.principal == nil)
    }

    // MARK: The module owns the order

    @Test("given a runtime, every security lane runs Sessions ahead of Authentication")
    func moduleLanes() throws {
        let module = FlightSecurityModule(validator: validator, sessions: runtime)
        for lane in [PipelineLane.default, .authentication, .authenticated] {
            let names = module.middleware.filter { $0.lane == lane && $0.name != "__lane" }.map(
                \.name)
            #expect(names.first?.hasSuffix(".Sessions") == true, "\(lane): \(names)")
            #expect(
                names.dropFirst().first?.hasSuffix(".Authentication") == true, "\(lane): \(names)")
        }
        let without = FlightSecurityModule(validator: validator)
        #expect(!without.middleware.contains { $0.name.hasSuffix(".Sessions") })
    }

    // MARK: End to end

    @Test("a browser signs in once and is authenticated by its cookie until it signs out")
    func endToEnd() async throws {
        let routes = [
            RouteRegistration(method: .post, path: "/login", source: "test") { context in
                try context.requireSession().signIn(testPrincipal(subject: "ada", roles: ["admin"]))
                return .status(.noContent)
            },
            RouteRegistration(method: .post, path: "/logout", source: "test") { context in
                try context.requireSession().signOut()
                return .status(.noContent)
            },
            RouteRegistration(
                method: .get, path: "/whoami", source: "test", pipelines: [.authenticated]
            ) {
                context in
                .text(try context.requirePrincipal().subject)
            },
        ]
        // The security module's lanes, with Sessions in front — and the
        // sessions module's default-lane contribution beside it, the way a
        // real composition has both.
        let sessionsModule = try FlightSessionsModule(
            configuration: Configuration(values: ["sessions.cookie-secure": "false"]), store: store)
        let client = try TestClient(
            routes: routes,
            middleware: sessionsModule.middleware
                + FlightSecurityModule(validator: validator, sessions: sessionsModule.runtime)
                .middleware)

        #expect(await client.get("/whoami").status == .unauthorized)

        let login = await client.post("/login")
        let cookie = try #require(
            login.headerValues("Set-Cookie").compactMap { $0.split(separator: ";").first }.first {
                $0.hasPrefix("session=")
            })
        let whoami = await client.get("/whoami", headers: [.cookie: String(cookie)])
        #expect(whoami.status == .ok)
        #expect(whoami.bodyText == "ada")
        #expect(
            store.entryCount == 1, "Sessions listed twice in the default lane still kept one record"
        )

        let logout = await client.post("/logout", headers: [.cookie: String(cookie)])
        let after = try #require(
            logout.headerValues("Set-Cookie").compactMap { $0.split(separator: ";").first }.first {
                $0.hasPrefix("session=")
            })
        #expect(after != cookie, "signing out regenerates the id")
        #expect(
            await client.get("/whoami", headers: [.cookie: String(after)]).status == .unauthorized)
    }
}
