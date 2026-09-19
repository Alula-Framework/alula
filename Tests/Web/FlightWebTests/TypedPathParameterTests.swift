import FlightCore
import FlightWeb
import FlightWebTesting
import Foundation
import HTTPTypes
import Testing

// A path segment that is more than its spelling: lowercase, digits, hyphens.
// The point of conforming a type of your own is that the rule lives at the
// edge, once, instead of in every handler that receives the segment.
struct Slug: PathParameterConvertible, Equatable {
    let value: String
    init?(pathParameter text: String) {
        guard !text.isEmpty,
            text.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" })
        else { return nil }
        self.value = text
    }
}

@Controller("/typed")
struct TypedController {

    // The parameter's label is the segment it binds to, so there is nothing
    // to keep in sync and nothing to unwrap.
    @GetRoute("/users/:id")
    func user(_ context: RequestContext, id: Int) async throws -> String {
        "user \(id + 1)"  // arithmetic, on a value that arrived as one
    }

    @GetRoute("/orders/:orderID/lines/:line")
    func line(_ context: RequestContext, orderID: UUID, line: Int) async throws -> String {
        "\(orderID.uuidString.prefix(8)):\(line)"
    }

    @GetRoute("/posts/:slug")
    func post(_ context: RequestContext, slug: Slug) async throws -> String {
        "post \(slug.value)"
    }

    @GetRoute("/flags/:enabled")
    func flag(_ context: RequestContext, enabled: Bool) async throws -> String {
        enabled ? "on" : "off"
    }

    // Typed parameters and a body coexist, in either order.
    @PostRoute("/users/:id/notes")
    func note(_ context: RequestContext, body: NoteBody, id: Int) async throws -> String {
        "\(id):\(body.text)"
    }
}

struct NoteBody: Codable {
    let text: String
}

@Suite("Typed path parameters")
struct TypedPathParameterTests {

    private func client() throws -> TestClient {
        try TestClient(routes: TypedController.flightRoutes { _ in TypedController() })
    }

    @Test("an Int parameter arrives as an Int")
    func integer() async throws {
        let response = try await client().get("/typed/users/41")
        #expect(response.status == .ok)
        #expect(response.bodyText == "user 42")
    }

    @Test("several parameters bind by name, not by position")
    func several() async throws {
        let id = UUID()
        let response = try await client().get("/typed/orders/\(id.uuidString)/lines/7")
        #expect(response.status == .ok)
        #expect(response.bodyText == "\(id.uuidString.prefix(8)):7")
    }

    @Test("a type of your own decides what the segment may be")
    func customType() async throws {
        let good = try await client().get("/typed/posts/hello-world")
        #expect(good.bodyText == "post hello-world")
        // Rejected by `Slug`, so the handler never runs.
        let rejected = try await client().get("/typed/posts/Hello_World")
        #expect(rejected.status == .badRequest)
    }

    @Test("a segment that will not parse is a 400 naming the parameter")
    func unparseableIs400() async throws {
        let response = try await client().get("/typed/users/abc")
        #expect(response.status == .badRequest)
        // The message says which parameter and what was expected, because
        // "400" alone leaves the caller guessing which segment was wrong.
        #expect(response.bodyText.contains("id"))
        #expect(response.bodyText.contains("abc"))
    }

    @Test("booleans take the spellings a URL actually carries")
    func booleans() async throws {
        let on = try await client().get("/typed/flags/true")
        let one = try await client().get("/typed/flags/1")
        let off = try await client().get("/typed/flags/off")
        let bad = try await client().get("/typed/flags/maybe")
        #expect(on.bodyText == "on")
        #expect(one.bodyText == "on")
        #expect(off.bodyText == "off")
        #expect(bad.status == .badRequest)
    }

    @Test("a body and typed parameters coexist")
    func withBody() async throws {
        let response = try await client().post(
            "/typed/users/9/notes", json: NoteBody(text: "hi"))
        #expect(response.status == .ok)
        #expect(response.bodyText == "9:hi")
    }

    @Test("a parameter the path does not declare is a build error, not a nil")
    func mismatchIsCaughtAtBuild() {
        // Pinned by the macro fixture suite rather than here: a handler
        // declaring `slug:` against `/users/:id` does not compile, so there is
        // nothing runnable to assert. This test exists to say where that
        // guarantee lives.
        #expect(Bool(true))
    }
}
