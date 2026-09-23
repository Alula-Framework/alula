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

    @Test("a principal round-trips through a session with its standard claims and no others")
    func principalCoding() throws {
        let principal = Principal(
            subject: "ada", issuer: "https://idp.example.com", roles: ["admin"], scopes: ["read"],
            claims: [
                "email": "ada@example.com", "email_verified": true, "name": "Ada Lovelace",
                "preferred_username": "ada", "tenant": "analytical-engines",
            ])
        let session = Session()
        try session.signIn(principal)
        let stored = try #require(try session.principal())
        #expect(stored.subject == "ada")
        #expect(stored.issuer == "https://idp.example.com")
        #expect(stored.roles == ["admin"])
        #expect(stored.scopes == ["read"])
        // The person survives; the token's other contents do not.
        #expect(stored.email == "ada@example.com")
        #expect(stored.emailVerified)
        #expect(stored.name == "Ada Lovelace")
        #expect(stored.preferredUsername == "ada")
        #expect(stored.claims["tenant"] == nil, "other claims are a fact about a token")
    }

    @Test("a session written before standard claims were kept still decodes")
    func legacySessionDecodes() throws {
        let legacy = Data(
            #"{"subject":"ada","issuer":"https://idp","roles":["admin"],"scopes":[]}"#.utf8)
        let principal = try JSONDecoder().decode(Principal.self, from: legacy)
        #expect(principal.subject == "ada")
        #expect(principal.email == nil)
        #expect(!principal.emailVerified)
        #expect(principal.claims.isEmpty)
    }

    @Test("email_verified is written only when asserted, not as a default false")
    func unassertedVerificationIsNotWritten() throws {
        let data = try JSONEncoder().encode(Principal(subject: "ada", issuer: "local"))
        #expect(!String(decoding: data, as: UTF8.self).contains("email_verified"))
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

    // MARK: Signing out everywhere

    /// A login route that signs in whoever `?as=` names, the logout-others
    /// route a password change would call, and who-am-I.
    private func revocationClient(_ store: any SessionStore) throws -> TestClient {
        let sessionsModule = try FlightSessionsModule(
            configuration: Configuration(values: ["sessions.cookie-secure": "false"]), store: store)
        let runtime = sessionsModule.runtime
        let routes = [
            RouteRegistration(method: .post, path: "/login", source: "test") { context in
                let subject = context.request.queryParam("as") ?? "ada"
                try context.requireSession().signIn(testPrincipal(subject: subject))
                return .status(.noContent)
            },
            RouteRegistration(
                method: .post, path: "/sign-out-others", source: "test", pipelines: [.authenticated]
            ) { context in
                let session = try context.requireSession()
                let ended = try await runtime.revokeSessions(
                    ownedBy: try context.requirePrincipal().subject, keeping: session.id)
                return .text("\(ended)")
            },
            RouteRegistration(
                method: .get, path: "/whoami", source: "test", pipelines: [.authenticated]
            ) { context in
                .text(try context.requirePrincipal().subject)
            },
        ]
        return try TestClient(
            routes: routes,
            middleware: sessionsModule.middleware
                + FlightSecurityModule(validator: validator, sessions: runtime).middleware)
    }

    private func signIn(_ client: TestClient, as subject: String) async throws -> String {
        let response = await client.post("/login?as=\(subject)")
        return try #require(
            response.headerValues("Set-Cookie").compactMap { $0.split(separator: ";").first }
                .first { $0.hasPrefix("session=") }
                .map(String.init))
    }

    @Test("signing in records the subject as the session's owner; signing out clears it")
    func ownerFollowsSignIn() throws {
        let session = Session()
        try session.signIn(testPrincipal(subject: "ada"))
        #expect(session.owner == "ada")
        session.signOut()
        #expect(session.owner == nil)
    }

    @Test(
        "sign out everywhere else: other sessions of the same person end, this one and others' do not"
    )
    func revokeOthers() async throws {
        let client = try revocationClient(store)
        let laptop = try await signIn(client, as: "ada")
        let phone = try await signIn(client, as: "ada")
        let grace = try await signIn(client, as: "grace")
        for cookie in [laptop, phone, grace] {
            #expect(await client.get("/whoami", headers: [.cookie: cookie]).status == .ok)
        }

        let ended = await client.post("/sign-out-others", headers: [.cookie: laptop])
        #expect(ended.bodyText == "1")
        #expect(await client.get("/whoami", headers: [.cookie: laptop]).status == .ok)
        #expect(await client.get("/whoami", headers: [.cookie: phone]).status == .unauthorized)
        #expect(await client.get("/whoami", headers: [.cookie: grace]).bodyText == "grace")
    }

    @Test("the in-memory store indexes by owner too")
    func inMemoryRevokes() async throws {
        let client = try revocationClient(InMemorySessionStore())
        let first = try await signIn(client, as: "ada")
        let second = try await signIn(client, as: "ada")
        _ = await client.post("/sign-out-others", headers: [.cookie: first])
        #expect(await client.get("/whoami", headers: [.cookie: second]).status == .unauthorized)
        #expect(await client.get("/whoami", headers: [.cookie: first]).status == .ok)
    }

    /// A store that does not index by owner.
    private final class PlainStore: SessionStore, @unchecked Sendable {
        private let inner = InMemorySessionStore()
        func load(_ id: SessionID) async throws -> Data? { try await inner.load(id) }
        func save(_ id: SessionID, _ record: Data, ttl: Duration) async throws {
            try await inner.save(id, record, ttl: ttl)
        }
        func delete(_ id: SessionID) async throws { try await inner.delete(id) }
    }

    @Test("a store that cannot index by owner says so rather than ending nothing")
    func unsupportedStore() async throws {
        let runtime = SessionRuntime(
            store: PlainStore(),
            settings: try SessionSettings(ttl: .seconds(60), cookieSecure: false))
        await #expect(throws: SessionRevocationUnsupported.self) {
            try await runtime.revokeSessions(ownedBy: "ada")
        }
    }

    // MARK: Absolute authenticated lifetime

    /// Sessions and the security lanes on a movable clock, with a one-hour
    /// authenticated lifetime and a much longer sliding TTL.
    private func lifetimeClient(_ clock: TestClock, store: RecordingSessionStore) throws
        -> TestClient
    {
        let runtime = SessionRuntime(
            store: store,
            settings: try SessionSettings(
                ttl: .seconds(14 * 24 * 3600), cookieSecure: false,
                authenticatedLifetime: .seconds(3600)),
            now: clock.nowProvider)
        let routes = [
            RouteRegistration(method: .post, path: "/login", source: "test") { context in
                let session = try context.requireSession()
                try session.set("cart", 3)
                try session.signIn(testPrincipal(subject: "ada"), at: clock.now)
                return .status(.noContent)
            },
            RouteRegistration(method: .get, path: "/cart", source: "test") { context in
                .text("\(try context.requireSession().get("cart", as: Int.self) ?? 0)")
            },
            RouteRegistration(
                method: .get, path: "/whoami", source: "test", pipelines: [.authenticated]
            ) { context in
                .text(try context.requirePrincipal().subject)
            },
        ]
        return try TestClient(
            routes: routes,
            middleware: MiddlewareRegistration.lane(.default, [Sessions(runtime: runtime)])
                + FlightSecurityModule(validator: nil, sessions: runtime).middleware)
    }

    /// The session cookie a response set, if it set one — most requests do
    /// not, and that is not a failure.
    private func newCookie(_ response: Response) -> String? {
        response.headerValues("Set-Cookie").compactMap { $0.split(separator: ";").first }
            .first { $0.hasPrefix("session=") }.map(String.init)
    }

    private func cookie(_ response: Response) throws -> String {
        try #require(newCookie(response))
    }

    @Test("a sign-in ends at its absolute lifetime however active the session stays")
    func absoluteLifetime() async throws {
        let clock = TestClock()
        let client = try lifetimeClient(clock, store: RecordingSessionStore())
        var session = try cookie(await client.post("/login"))

        // Used every twenty minutes — the sliding TTL would never idle out.
        for _ in 0..<2 {
            clock.advance(by: 20 * 60)
            let response = await client.get("/whoami", headers: [.cookie: session])
            #expect(response.status == .ok)
            session = newCookie(response) ?? session
        }
        clock.advance(by: 21 * 60)  // 61 minutes after signing in
        let expired = await client.get("/whoami", headers: [.cookie: session])
        #expect(expired.status == .unauthorized)
        session = newCookie(expired) ?? session

        // Signed out, not wiped: the rest of the session is still there.
        #expect(await client.get("/cart", headers: [.cookie: session]).bodyText == "3")
        #expect(await client.get("/whoami", headers: [.cookie: session]).status == .unauthorized)
    }

    @Test("a sign-in recorded before the time was kept is stamped once, not signed out")
    func legacySignInIsStamped() async throws {
        let clock = TestClock()
        let store = RecordingSessionStore()
        let client = try lifetimeClient(clock, store: store)
        // A session as 0.32.0 wrote it: a principal and no sign-in time.
        let id = SessionID.generate()
        let principal = try JSONEncoder().encode(testPrincipal(subject: "ada"))
        try store.seed(
            id,
            record: SessionRecord(
                values: [Session.principalKey: principal], createdAt: clock.now,
                expiresAt: clock.now.addingTimeInterval(86_400), owner: "ada"))
        let legacy = "session=\(id.cookieValue)"

        #expect(await client.get("/whoami", headers: [.cookie: legacy]).status == .ok)
        clock.advance(by: 3601)
        #expect(
            await client.get("/whoami", headers: [.cookie: legacy]).status == .unauthorized,
            "it had one full lifetime from the stamp, and no more")
    }
}
