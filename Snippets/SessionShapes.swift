// Every shape Docs/sessions.md claims, compiled.
//
// A doc example that does not compile costs a reader the time to find out.
// This builds as part of `swift build`, so a rename that invalidates the
// prose breaks the build.

import FlightCore
import FlightWeb
import Foundation

// snippet.hide
struct Account: Sendable { let id: UUID }
struct LoginForm: Codable {
    let email: String
    let password: String
}
@Service
struct AccountService {
    func authenticate(_ email: String, _ password: String) async throws -> Account {
        Account(id: UUID())
    }
}
// snippet.show

@Controller("/account")
struct AccountController {
    @Inject var accounts: AccountService

    @PostRoute("/login")
    func login(_ context: RequestContext, body: LoginForm) async throws -> Response {
        let account = try await accounts.authenticate(body.email, body.password)
        let session = try context.requireSession()
        try session.set("account", account.id)
        session.regenerate()
        try session.flash("notice", "Welcome back.")
        return .seeOther("/")
    }

    @PostRoute("/logout")
    func logout(_ context: RequestContext) throws -> Response {
        try context.requireSession().destroy()
        return .seeOther("/")
    }
}

@Controller("/")
struct HomeController {
    @GetRoute("/")
    func home(_ context: RequestContext) throws -> String {
        let session = try context.requireSession()
        let notice = try session.flashed("notice", as: String.self)
        let accountID = try session.get("account", as: UUID.self)
        return "\(notice ?? "") \(accountID.map { "\($0)" } ?? "signed out")"
    }
}

// The "Writing a store" example: any client with get, set-with-TTL and
// delete, wrapped as a `SessionStore` and provided from a module by type.
protocol KeyValueClient: Sendable {
    func get(_ key: String) async throws -> Data?
    func set(_ key: String, _ value: Data, expiringIn ttl: Duration) async throws
    func delete(_ key: String) async throws
}

final class KeyValueSessionStore: SessionStore, Sendable {
    let client: any KeyValueClient

    init(client: any KeyValueClient) { self.client = client }

    func load(_ id: SessionID) async throws -> Data? {
        guard let data = try await client.get("session:" + id.cookieValue) else { return nil }
        // A backend without native expiry checks the record's own clock, so
        // an expired session reads as absent rather than as a ghost.
        guard try SessionRecord(decoding: data).expiresAt > Date() else {
            try await client.delete("session:" + id.cookieValue)
            return nil
        }
        return data
    }

    func save(_ id: SessionID, _ record: Data, ttl: Duration) async throws {
        try await client.set("session:" + id.cookieValue, record, expiringIn: ttl)
    }

    func delete(_ id: SessionID) async throws {
        try await client.delete("session:" + id.cookieValue)
    }
}

// snippet.hide
struct MyKeyValueClient: KeyValueClient {
    func get(_ key: String) async throws -> Data? { nil }
    func set(_ key: String, _ value: Data, expiringIn ttl: Duration) async throws {}
    func delete(_ key: String) async throws {}
}
// snippet.show

struct KeyValueSessionsModule: FlightModule {
    /// Matched by type to `FlightSessionsModule`'s `store:` parameter.
    let store: any SessionStore

    init(client: MyKeyValueClient) {
        store = KeyValueSessionStore(client: client)
    }
}

func sessionShapes(configuration: Configuration) throws {
    // The module, built the way the composition root builds it: from
    // configuration, with an optional store an adapter module provides.
    let module = try FlightSessionsModule(configuration: configuration)
    _ = module.runtime.settings.cookieName
    _ = module.middleware

    // A store of your own is the seam, provided from a module by type.
    struct MyStoreModule: FlightModule {
        let store: any SessionStore = InMemorySessionStore()
    }
    _ = MyStoreModule()

    // The settings a test hands a runtime directly.
    _ = try SessionSettings(ttl: .seconds(3600), cookieSecure: false)

    // Session ids are opaque; the only thing to do with one is carry it.
    let id = SessionID.generate()
    _ = SessionID(cookieValue: id.cookieValue)
}
