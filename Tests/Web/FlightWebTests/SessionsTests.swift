import FlightCore
import FlightSessions
import FlightSessionsTesting
import FlightWeb
import FlightWebTesting
import Foundation
import HTTPTypes
import Synchronization
import Testing

@Controller("/")
private struct SessionTestController {
    @GetRoute("/read")
    func read(_ context: RequestContext) throws -> String {
        try context.requireSession().get("user", as: String.self) ?? "nobody"
    }

    @PostRoute("/login")
    func login(_ context: RequestContext) throws -> String {
        let session = try context.requireSession()
        try session.set("user", context.request.queryParam("as") ?? "ada")
        session.regenerate()
        return "signed in"
    }

    @PostRoute("/touch")
    func touch(_ context: RequestContext) throws -> String {
        try context.requireSession().set("touched", true)
        return "touched"
    }

    @PostRoute("/logout")
    func logout(_ context: RequestContext) throws -> String {
        try context.requireSession().destroy()
        return "signed out"
    }

    @PostRoute("/save")
    func save(_ context: RequestContext) throws -> Response {
        try context.requireSession().flash("notice", "Saved.")
        return .seeOther("/notice")
    }

    @GetRoute("/notice")
    func notice(_ context: RequestContext) throws -> String {
        try context.requireSession().flashed("notice", as: String.self) ?? "no notice"
    }

    @GetRoute("/boom")
    func boom(_ context: RequestContext) throws -> String {
        try context.requireSession().set("before-failure", true)
        throw HTTPError(.internalServerError, "boom")
    }
}

/// A clock the test moves.
private final class TestClock: Sendable {
    private let storage: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_750_000_000)) {
        storage = Mutex(start)
    }

    var now: Date { storage.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        storage.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    var nowProvider: @Sendable () -> Date {
        { self.now }
    }
}

@Suite("Sessions middleware")
struct SessionsTests {
    private let store = RecordingSessionStore()
    private let clock = TestClock()

    private func client(
        settings: SessionSettings? = nil, store: (any SessionStore)? = nil
    ) throws -> TestClient {
        let runtime = SessionRuntime(
            store: store ?? self.store,
            settings: try settings ?? SessionSettings(ttl: .seconds(3600)),
            now: clock.nowProvider)
        return try TestClient(
            routes: SessionTestController.flightRoutes { _ in SessionTestController() },
            middleware: MiddlewareRegistration.lane(.default, [Sessions(runtime: runtime)]))
    }

    /// The id a `Set-Cookie` handed out.
    private func sessionCookie(_ response: Response, name: String = "session") -> String? {
        for header in response.headerValues("Set-Cookie") {
            guard let pair = header.split(separator: ";").first,
                let equals = pair.firstIndex(of: "="), pair[..<equals] == name
            else { continue }
            return String(pair[pair.index(after: equals)...])
        }
        return nil
    }

    // MARK: __Host- prefix

    @Test("with the host prefix on, the cookie is set and read as __Host-<name>")
    func hostPrefix() async throws {
        let client = try client(
            settings: SessionSettings(ttl: .seconds(3600), cookieHostPrefix: true))
        let login = await client.post("/login?user=ada")
        let id = try #require(sessionCookie(login, name: "__Host-session"))
        #expect(sessionCookie(login, name: "session") == nil)
        let setCookie = try #require(login.header("Set-Cookie"))
        #expect(setCookie.contains("Secure") && setCookie.contains("Path=/"))
        #expect(!setCookie.contains("Domain"))
        let read = await client.get("/read", headers: [.cookie: "__Host-session=\(id)"])
        #expect(read.bodyText == "ada")
    }

    @Test("the host prefix refuses settings a browser would drop the cookie for")
    func hostPrefixRequirements() {
        for settings in [
            { try SessionSettings(cookieSecure: false, cookieHostPrefix: true) },
            { try SessionSettings(cookiePath: "/app", cookieHostPrefix: true) },
            { try SessionSettings(cookieDomain: "example.com", cookieHostPrefix: true) },
        ] as [() throws -> SessionSettings] {
            #expect(throws: SessionConfigurationError.hostPrefixRequirementsNotMet) {
                _ = try settings()
            }
        }
    }

    @Test("the authenticated lifetime defaults to a week and must be positive")
    func authenticatedLifetimeSetting() throws {
        #expect(try SessionSettings().authenticatedLifetime == .seconds(7 * 24 * 3600))
        #expect(
            try SessionSettings(
                configuration: Configuration(values: ["sessions.authenticated-lifetime": "12h"])
            ).authenticatedLifetime == .seconds(12 * 3600))
        #expect(throws: SessionConfigurationError.self) {
            try SessionSettings(authenticatedLifetime: .zero)
        }
    }

    // MARK: Nothing until something is written

    @Test("a request that only reads leaves no record and sets no cookie")
    func readOnlyCostsNothing() async throws {
        let response = await (try client()).get("/read")
        #expect(response.status == .ok)
        #expect(response.bodyText == "nobody")
        #expect(response.header("Set-Cookie") == nil)
        #expect(store.entryCount == 0)
        #expect(store.operations.isEmpty, "no cookie, so the store was not even asked")
    }

    @Test("a cookie that is not a session id is ignored, not looked up")
    func malformedCookie() async throws {
        let response = await (try client()).get("/read", headers: [.cookie: "session=garbage"])
        #expect(response.status == .ok)
        #expect(store.operations.isEmpty)
    }

    @Test("a well-formed cookie naming nothing is a fresh visit")
    func unknownID() async throws {
        let stale = SessionID.generate()
        let response = await (try client()).get(
            "/read", headers: [.cookie: "session=\(stale.cookieValue)"])
        #expect(response.status == .ok)
        #expect(response.bodyText == "nobody")
        #expect(
            response.header("Set-Cookie") == nil,
            "nothing was written, so the stale cookie is left alone")
        #expect(store.operations == [.load(stale)])
    }

    // MARK: A session's life

    @Test("the first write stores a record and sets the cookie with the safe attributes")
    func firstWrite() async throws {
        let response = await (try client()).post("/login")
        #expect(response.status == .ok)
        let header = try #require(response.header("Set-Cookie"))
        #expect(header.contains("HttpOnly"))
        #expect(header.contains("Secure"), "on by default: a session cookie is a bearer credential")
        #expect(header.contains("SameSite=Lax"))
        #expect(header.contains("Path=/"))
        #expect(header.contains("Max-Age=3600"))

        let value = try #require(sessionCookie(response))
        let id = try #require(SessionID(cookieValue: value))
        let record = try #require(try store.record(for: id))
        #expect(record.values["user"] == Data("\"ada\"".utf8))
        #expect(store.ttl(for: id) == .seconds(3600))
    }

    @Test("the cookie comes back and the session with it")
    func roundTrip() async throws {
        let client = try client()
        let login = await client.post("/login?as=grace")
        let cookie = try #require(sessionCookie(login))

        let read = await client.get("/read", headers: [.cookie: "session=\(cookie)"])
        #expect(read.bodyText == "grace")
        #expect(
            read.header("Set-Cookie") == nil,
            "an untouched session with most of its life left is not rewritten")
    }

    @Test("login regenerates: a planted id is not the one that ends up signed in")
    func fixation() async throws {
        let client = try client()
        // A session exists before login — the attacker's planted id.
        let planted = try #require(sessionCookie(await client.post("/touch")))
        let login = await client.post("/login", headers: [.cookie: "session=\(planted)"])
        let signedIn = try #require(sessionCookie(login))
        #expect(signedIn != planted)
        #expect(store.data(for: SessionID(cookieValue: planted)!) == nil, "the old id is deleted")
        let read = await client.get("/read", headers: [.cookie: "session=\(signedIn)"])
        #expect(read.bodyText == "ada")
    }

    @Test("logout deletes the record and expires the cookie")
    func logout() async throws {
        let client = try client()
        let cookie = try #require(sessionCookie(await client.post("/login")))
        let logout = await client.post("/logout", headers: [.cookie: "session=\(cookie)"])
        let header = try #require(logout.header("Set-Cookie"))
        #expect(header.hasPrefix("session=;"))
        #expect(header.contains("Max-Age=0"))
        #expect(store.entryCount == 0)
        let read = await client.get("/read", headers: [.cookie: "session=\(cookie)"])
        #expect(read.bodyText == "nobody")
    }

    @Test("a session past half its life is renewed on a read, cookie included")
    func slidingRenewal() async throws {
        let client = try client()
        let cookie = try #require(sessionCookie(await client.post("/login")))
        clock.advance(by: 1900)
        let read = await client.get("/read", headers: [.cookie: "session=\(cookie)"])
        #expect(read.bodyText == "ada")
        #expect(sessionCookie(read) == cookie, "renewed under the same id, with a fresh Max-Age")
        let id = try #require(SessionID(cookieValue: cookie))
        let record = try #require(try store.record(for: id))
        #expect(record.expiresAt == clock.now.addingTimeInterval(3600))
    }

    @Test("a flash survives exactly one redirect")
    func flash() async throws {
        let client = try client()
        let save = await client.post("/save")
        #expect(save.status == .seeOther)
        let cookie = try #require(sessionCookie(save))
        let first = await client.get("/notice", headers: [.cookie: "session=\(cookie)"])
        #expect(first.bodyText == "Saved.")
        let second = await client.get("/notice", headers: [.cookie: "session=\(cookie)"])
        #expect(second.bodyText == "no notice")
    }

    @Test("what the handler did is committed even when its response is an error")
    func committedOnHandlerFailure() async throws {
        let response = await (try client()).get("/boom")
        #expect(response.status == .internalServerError)
        #expect(sessionCookie(response) != nil)
        #expect(store.entryCount == 1)
    }

    // MARK: Failure

    @Test("a store that cannot load is a 503 with nothing in the body")
    func storeDownOnLoad() async throws {
        store.misbehave()
        let response = await (try client()).get(
            "/read", headers: [.cookie: "session=\(SessionID.generate().cookieValue)"])
        #expect(response.status == .serviceUnavailable)
        #expect(!response.bodyText.contains("misbehaving"))
    }

    @Test("a store that cannot save is a 503 after the handler ran")
    func storeDownOnSave() async throws {
        let client = try client()
        store.misbehave()
        let response = await client.post("/login")
        #expect(response.status == .serviceUnavailable)
        #expect(response.header("Set-Cookie") == nil)
    }

    @Test("a record that does not decode starts a fresh session instead of failing the request")
    func undecodableRecord() async throws {
        let id = SessionID.generate()
        store.seed(id, data: Data("not json".utf8))
        let response = await (try client()).get(
            "/read", headers: [.cookie: "session=\(id.cookieValue)"])
        #expect(response.status == .ok)
        #expect(response.bodyText == "nobody")
    }

    @Test(
        "requireSession without the middleware is a 500 that names the fix in the log, not the body"
    )
    func notConfigured() async throws {
        let client = try TestClient(
            routes: SessionTestController.flightRoutes { _ in SessionTestController() })
        let response = await client.get("/read")
        #expect(response.status == .internalServerError)
        #expect(!response.bodyText.contains("FlightSessionsModule"))
        #expect(SessionNotConfiguredError().description.contains("FlightSessionsModule"))
    }

    // MARK: Settings reach the cookie

    @Test("cookie attributes follow the settings")
    func cookieAttributes() async throws {
        let settings = try SessionSettings(
            cookieName: "sid", ttl: .seconds(60), cookieSecure: false, cookieSameSite: .strict,
            cookiePath: "/app", cookieDomain: "example.com")
        let client = try client(settings: settings)
        let login = await client.post("/login")
        let header = try #require(login.header("Set-Cookie"))
        #expect(header.hasPrefix("sid="))
        #expect(!header.contains("Secure"))
        #expect(header.contains("SameSite=Strict"))
        #expect(header.contains("Path=/app"))
        #expect(header.contains("Domain=example.com"))
        #expect(header.contains("Max-Age=60"))

        let cookie = try #require(sessionCookie(login, name: "sid"))
        let logout = await client.post("/logout", headers: [.cookie: "sid=\(cookie)"])
        let expiring = try #require(logout.header("Set-Cookie"))
        #expect(
            expiring.contains("Path=/app"),
            "deletion must match what set it, or the browser keeps the original")
        #expect(expiring.contains("Domain=example.com"))
    }
}

@Suite("FlightSessionsModule")
struct FlightSessionsModuleTests {

    @Test("with no adapter the store is in-memory and the middleware is in the default lane")
    func defaults() throws {
        let module = try FlightSessionsModule(configuration: Configuration())
        #expect(module.runtime.store is InMemorySessionStore)
        #expect(module.runtime.settings == (try SessionSettings()))
        #expect(
            module.middleware.contains { $0.lane == .default && $0.name.hasSuffix(".Sessions") })
    }

    @Test("an adapter's store wins over the in-memory default")
    func adapter() throws {
        let store = RecordingSessionStore()
        let module = try FlightSessionsModule(configuration: Configuration(), store: store)
        #expect(module.runtime.store is RecordingSessionStore)
    }

    @Test("configuring the Valkey URL without listing its module fails composition, naming it")
    func unloadedAdapter() throws {
        let configuration = Configuration(values: ["sessions.valkey.url": "valkey://localhost"])
        #expect(throws: UnloadedAdapterError.self) {
            try FlightSessionsModule(configuration: configuration)
        }
        do {
            _ = try FlightSessionsModule(configuration: configuration)
        } catch let error as UnloadedAdapterError {
            #expect(error.module == "FlightSessionsValkeyModule")
            #expect(error.configurationKey == "sessions.valkey.url")
        }
    }

    @Test("settings are read from sessions.*")
    func settings() throws {
        let module = try FlightSessionsModule(
            configuration: Configuration(values: [
                "sessions.cookie-name": "sid",
                "sessions.ttl": "2h",
                "sessions.cookie-secure": "false",
                "sessions.cookie-same-site": "Strict",
                "sessions.cookie-path": "/app",
                "sessions.cookie-domain": "example.com",
                "sessions.memory.max-entries": "10",
            ]))
        let settings = module.runtime.settings
        #expect(settings.cookieName == "sid")
        #expect(settings.ttl == .seconds(7200))
        #expect(settings.cookieSecure == false)
        #expect(settings.cookieSameSite == .strict)
        #expect(settings.cookiePath == "/app")
        #expect(settings.cookieDomain == "example.com")
        #expect(settings.memoryMaxEntries == 10)
        #expect((module.runtime.store as? InMemorySessionStore)?.maxEntries == 10)
    }

    @Test("SameSite=None without Secure is refused, because no browser would send that cookie back")
    func sameSiteNone() throws {
        let configuration = Configuration(values: [
            "sessions.cookie-same-site": "none", "sessions.cookie-secure": "false",
        ])
        #expect(throws: SessionConfigurationError.sameSiteNoneRequiresSecure) {
            try FlightSessionsModule(configuration: configuration)
        }
    }

    @Test("a cookie name that cannot be a Set-Cookie name is refused rather than trapped on")
    func badCookieName() throws {
        #expect(throws: SessionConfigurationError.invalidCookieName("my session")) {
            try FlightSessionsModule(
                configuration: Configuration(values: ["sessions.cookie-name": "my session"]))
        }
    }

    @Test("a TTL that is not positive, and a bound that is not positive, are refused")
    func bounds() throws {
        #expect(throws: SessionConfigurationError.invalidMaxEntries(0)) {
            try FlightSessionsModule(
                configuration: Configuration(values: ["sessions.memory.max-entries": "0"]))
        }
        #expect(throws: SessionConfigurationError.nonPositiveTTL(.zero)) {
            try FlightSessionsModule(configuration: Configuration(values: ["sessions.ttl": "0s"]))
        }
    }

    @Test("an unrecognised same-site value fails, naming the key")
    func badSameSite() throws {
        #expect(throws: (any Error).self) {
            try FlightSessionsModule(
                configuration: Configuration(values: ["sessions.cookie-same-site": "sideways"]))
        }
    }
}
