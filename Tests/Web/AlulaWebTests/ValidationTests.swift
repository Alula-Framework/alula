import AlulaCore
import AlulaWeb
import AlulaWebTesting
import Foundation
import HTTPTypes
import Testing

struct SignupBody: Codable, Validatable {
    var name: String
    var email: String
    var age: Int
    var nickname: String?
    var pets: [Pet] = []

    struct Pet: Codable, Validatable {
        var name: String
        func validate(_ v: inout Validation) {
            v.check("name", name, .notBlank)
        }
    }

    func validate(_ v: inout Validation) {
        v.check("name", name, .notBlank, .length(max: 20))
        v.check("email", email, .email)
        v.check("age", age, .range(13...130))
        v.check("nickname", nickname, .length(min: 2))
        v.each("pets", pets)
    }
}

struct PageQuery: Decodable, Validatable {
    var page: Int
    func validate(_ v: inout Validation) {
        v.check("page", page, .min(1))
    }
}

@Controller("/v")
struct ValidatingController {
    @PostRoute("/signup")
    func signup(_ context: RequestContext, body: SignupBody) async throws -> String {
        "welcome \(body.name)"
    }

    @GetRoute("/items")
    func items(_ context: RequestContext, query: PageQuery) async throws -> String {
        "page \(query.page)"
    }
}

@Suite("Declarative validation")
struct ValidationTests {
    struct Problem: Decodable {
        let status: Int
        let detail: String
        let errors: [FieldError]
    }

    private func client() throws -> TestClient {
        try TestClient(routes: ValidatingController.alulaRoutes { _ in ValidatingController() })
    }

    @Test("a valid body reaches the handler")
    func valid() async throws {
        let response = try await client().post(
            "/v/signup", json: SignupBody(name: "Ada", email: "ada@example.com", age: 36))
        #expect(response.status == .ok)
        #expect(response.bodyText == "welcome Ada")
    }

    /// Foundation's parser refuses nesting past 512 levels before any
    /// decoding starts, so a deeply nested body cannot exhaust the stack.
    /// Pinned because alula relies on it rather than scanning bodies itself.
    @Test("a body nested far too deep is a 400, not a crash")
    func deepNesting() async throws {
        let depth = 100_000
        let body = #"{"name":"#.utf8 + Array(repeating: UInt8(ascii: "["), count: depth)
            + Array(repeating: UInt8(ascii: "]"), count: depth) + #"}"#.utf8
        let response = await (try client()).post(
            "/v/signup", headers: [.contentType: "application/json"], body: Data(body))
        #expect(response.status == .badRequest)
    }

    @Test("every failing field is reported at once, as a 422 problem with errors")
    func allFieldsAtOnce() async throws {
        let response = try await client().post(
            "/v/signup",
            json: SignupBody(
                name: " ", email: "not-an-email", age: 7, nickname: "x",
                pets: [.init(name: "Rex"), .init(name: "")]))
        #expect(response.status == .unprocessableContent)
        #expect(response.headers[.contentType] == "application/problem+json")
        let problem = try JSONDecoder().decode(Problem.self, from: response.bodyData ?? Data())
        #expect(problem.status == 422)
        #expect(problem.detail == "5 fields are invalid")
        #expect(
            problem.errors == [
                FieldError(field: "name", message: "must not be blank"),
                FieldError(field: "email", message: "must be an email address"),
                FieldError(field: "age", message: "must be between 13 and 130"),
                FieldError(field: "nickname", message: "must be at least 2 characters"),
                FieldError(field: "pets[1].name", message: "must not be blank"),
            ])
    }

    @Test("the first failing rule wins per field: blank is not also too short")
    func firstRulePerField() {
        struct Name: Validatable {
            let value: String
            func validate(_ v: inout Validation) {
                v.check("name", value, .notBlank, .length(min: 3))
            }
        }
        #expect(throws: ValidationFailure(errors: [FieldError(field: "name", message: "must not be blank")])) {
            try Name(value: "").validated()
        }
    }

    @Test("a malformed body is still a 400 from decoding, not a 422")
    func shapeBeforeMeaning() async throws {
        let response = try await client().post(
            "/v/signup", headers: [.contentType: "application/json"], body: Data(#"{"name":"Ada"}"#.utf8))
        #expect(response.status == .badRequest)
    }

    @Test("query structs are validated too")
    func query() async throws {
        #expect(try await client().get("/v/items?page=2").bodyText == "page 2")
        let response = try await client().get("/v/items?page=0")
        #expect(response.status == .unprocessableContent)
        #expect(response.bodyText.contains("\"field\":\"page\""))
    }

    @Test("rules: email, oneOf, matches, count")
    func rules() {
        func fails<V>(_ rule: ValidationRule<V>, _ value: V) -> Bool { rule.check(value) != nil }
        #expect(fails(.email, "a@b"))
        #expect(fails(.email, "a b@example.com"))
        #expect(!fails(.email, "ada+x@example.co.uk"))
        #expect(fails(.oneOf(["red", "blue"]), "green"))
        #expect(fails(.matches("[a-z]+"), "abc1"))
        #expect(!fails(.matches("[a-z]+"), "abc"))
        #expect(fails(ValidationRule<[Int]>.count(max: 2), [1, 2, 3]))
    }
}
