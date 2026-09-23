import AlulaCore
import AlulaWeb
import AlulaWebTesting
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
        try TestClient(routes: TypedController.alulaRoutes { _ in TypedController() })
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

// MARK: - Query parameters as a struct

/// Absence is ordinary in a query string, so most fields are optional. A
/// non-optional one means the request must carry it — Swift's synthesized
/// `Decodable` throws on a missing key rather than using a property default,
/// and that reads correctly here: required means required.
struct ListFilters: Decodable, Equatable {
    var search: String?
    var page: Int?
    var tags: [String]?
    /// Required: a list endpoint that cannot say which tenant it is for has
    /// no sensible answer.
    var tenant: String
}

@Controller("/q")
struct QueryController {

    @GetRoute("/posts")
    func list(_ context: RequestContext, query: ListFilters) async throws -> String {
        let tags = query.tags?.joined(separator: "+") ?? "-"
        return "\(query.tenant)|\(query.search ?? "-")|\(query.page ?? 1)|\(tags)"
    }

    // Path, query and body in one signature.
    @PostRoute("/tenants/:tenantID/posts")
    func create(
        _ context: RequestContext, body: NoteBody, query: ListFilters, tenantID: Int
    ) async throws -> String {
        "\(tenantID):\(query.tenant):\(body.text)"
    }
}

@Suite("Query parameters as a struct")
struct QueryStructTests {

    private func client() throws -> TestClient {
        try TestClient(routes: QueryController.alulaRoutes { _ in QueryController() })
    }

    @Test("optional fields are absent rather than an error")
    func optionalsAreOptional() async throws {
        let response = try await client().get("/q/posts?tenant=acme")
        #expect(response.status == .ok)
        #expect(response.bodyText == "acme|-|1|-")
    }

    @Test("values arrive parsed, not as strings")
    func parsed() async throws {
        let response = try await client().get("/q/posts?tenant=acme&page=3&search=swift")
        #expect(response.bodyText == "acme|swift|3|-")
    }

    @Test("a repeated key collects into an array")
    func repeatedKeys() async throws {
        let response = try await client().get("/q/posts?tenant=acme&tags=a&tags=b")
        #expect(response.bodyText == "acme|-|1|a+b")
    }

    @Test("a missing required field is a 400 naming it")
    func missingRequired() async throws {
        let response = try await client().get("/q/posts?page=2")
        #expect(response.status == .badRequest)
        #expect(response.bodyText.contains("tenant"))
    }

    @Test("a value of the wrong type is a 400 naming the parameter")
    func wrongType() async throws {
        let response = try await client().get("/q/posts?tenant=acme&page=soon")
        #expect(response.status == .badRequest)
        #expect(response.bodyText.contains("page"))
    }

    @Test("percent-encoding is decoded")
    func percentEncoding() async throws {
        let response = try await client().get("/q/posts?tenant=acme&search=hello%20world")
        #expect(response.bodyText == "acme|hello world|1|-")
    }

    @Test("path, query and body coexist in one handler")
    func allThree() async throws {
        let response = try await client().post(
            "/q/tenants/7/posts?tenant=acme", json: NoteBody(text: "hi"))
        #expect(response.status == .ok)
        #expect(response.bodyText == "7:acme:hi")
    }
}

// MARK: - Argument order

private struct Note: Codable, Equatable { let text: String }

/// Both orders of `body:` against a path parameter. The generated call has to
/// follow the handler's declaration order, because Swift requires arguments
/// in that order — emitting a fixed one made a handler that put the path
/// parameter first fail with `argument 'slug' must precede argument 'body'`,
/// reported inside the macro expansion, for a rule nothing documented.
@Controller("/order")
private struct ArgumentOrderController {
    @PostRoute("/before/:slug")
    func pathFirst(_ context: RequestContext, slug: String, body: Note) async throws -> String {
        "\(slug):\(body.text)"
    }

    @PostRoute("/after/:slug")
    func bodyFirst(_ context: RequestContext, body: Note, slug: String) async throws -> String {
        "\(slug):\(body.text)"
    }

    @GetRoute("/mixed/:a/:b")
    func several(_ context: RequestContext, b: Int, a: String) async throws -> String {
        "\(a):\(b)"
    }

    /// All three kinds interleaved, path first. The emission used to be a
    /// fixed body-query-segments order, so every arrangement but one failed.
    @PostRoute("/all/:tenant/:id")
    func everything(
        _ context: RequestContext, tenant: String, query: Page, id: Int, body: Note
    ) async throws -> String {
        "\(tenant)|\(id)|\(body.text)|\(query.page ?? 0)"
    }
}

private struct Page: Codable, Equatable { let page: Int? }

@Suite("Handler argument order")
struct ArgumentOrderTests {
    private func client() throws -> TestClient {
        try TestClient(
            routes: ArgumentOrderController.alulaRoutes { _ in ArgumentOrderController() })
    }

    @Test("a path parameter declared before the body")
    func pathBeforeBody() async throws {
        let response = try await (try client()).post("/order/before/abc", json: Note(text: "hi"))
        #expect(response.bodyText.contains("abc:hi"))
    }

    @Test("a path parameter declared after the body")
    func bodyBeforePath() async throws {
        let response = try await (try client()).post("/order/after/xyz", json: Note(text: "yo"))
        #expect(response.bodyText.contains("xyz:yo"))
    }

    @Test("body, query and path parameters interleaved in any order")
    func allThreeKinds() async throws {
        let response = try await (try client()).post(
            "/order/all/acme/7?page=3", json: Note(text: "n"))
        #expect(response.bodyText.contains("acme|7|n|3"))
    }

    @Test("several path parameters in an order the path does not use")
    func reorderedSegments() async throws {
        // `:a/:b` in the path, `b:` then `a:` in the handler — the binding is
        // by name, so the declaration order is free and the call must follow it.
        let response = await (try client()).get("/order/mixed/hello/42")
        #expect(response.bodyText.contains("hello:42"))
    }
}
