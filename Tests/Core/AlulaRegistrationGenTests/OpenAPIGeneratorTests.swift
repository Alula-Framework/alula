import Foundation
import Testing

@Suite("OpenAPI document generation")
struct OpenAPIGeneratorTests {
    private let generator = GeneratorTests()

    private let sources: [String: String] = [
        "Main.swift": """
            import AlulaWeb
            struct AlulaOpenAPIModule: AlulaModule {
            init(configuration: Configuration, document: OpenAPIDocument) throws {}
            }
            @main struct Main {
            static func main() async {
            await Alula.run(configuration: .load(), modules: [AlulaOpenAPIModule.self])
            }
            }
            """,
        "Controller.swift": """
            import AlulaWeb
            @Controller("/orders")
            struct OrderController {
                @GetRoute("/:id")
                func show(_ context: RequestContext, id: UUID) async throws -> Order { fatalError() }

                @GetRoute("")
                func list(_ context: RequestContext, query: OrderFilter) async throws -> [Order] { [] }

                @PostRoute("")
                func create(_ context: RequestContext, body: NewOrder) async throws -> Order { fatalError() }

                @DeleteRoute("/:id")
                func remove(_ context: RequestContext, id: UUID) async throws {}

                @GetRoute("/files/:bucket/**")
                func file(_ context: RequestContext) -> Response { .noContent }
            }
            """,
        // A plain file: no Alula attribute at all, which is where DTOs live.
        "Models.swift": """
            import Foundation
            struct Order: Codable {
                let id: UUID
                let status: Status
                let lines: [Line]
                let note: String?
                let placedAt: Date
                let customer: Loadable<Customer>
                var total: Double { 0 }
                static let limit = 5

                enum Status: String, Codable { case open, shipped = "SHIPPED" }
                struct Line: Codable {
                    let sku: String
                    let quantity: Int
                    enum CodingKeys: String, CodingKey { case sku = "item_sku", quantity }
                }
            }
            struct Customer: Codable { let name: String }
            struct NewOrder: Decodable, Validatable {
                let lines: [Order.Line]
                let tags: [String: String]
                func validate(_ v: inout Validation) {}
            }
            struct OrderFilter: Decodable {
                let status: Order.Status?
                let page: Int
            }
            """,
    ]

    private func document() throws -> [String: Any] {
        let result = try generator.generate(sources)
        #expect(result.exitCode == 0)
        let text = result.generated
        #expect(text.contains("alulaOpenAPIModule = try AlulaOpenAPIModule(configuration: configuration, document: .init(generatedJSON: alulaOpenAPIJSON()))"))
        let start = try #require(text.range(of: "###\""))
        let end = try #require(text.range(of: "\"###", range: start.upperBound..<text.endIndex))
        let json = String(text[start.upperBound..<end.lowerBound])
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// Handlers return `Response` to pick a status far more often than to
    /// hide a body; on by default, ALU-OAPI-3002 warned on most routes of
    /// the starter templates. It is a check a team turns on.
    @Test("a Response handler is not a warning unless alula.yaml asks for the check")
    func undocumentedResponsesAreOptIn() throws {
        let quiet = try generator.generate(sources)
        #expect(!quiet.diagnostics.contains("[ALU-OAPI-3002]"), "\(quiet.diagnostics)")
        let strict = try generator.generate(
            sources, alulaYAML: "openapi:\n  warn-undocumented-responses: true\n")
        #expect(strict.diagnostics.contains("[ALU-OAPI-3002]"))
    }

    @Test("paths: methods, templated parameters, query fields, bodies and responses")
    func paths() throws {
        let document = try document()
        let paths = try #require(document["paths"] as? [String: [String: [String: Any]]])
        #expect(Set(paths.keys) == ["/orders", "/orders/{id}", "/orders/files/{bucket}/{rest}"])

        let show = try #require(paths["/orders/{id}"]?["get"])
        let idParameter = try #require((show["parameters"] as? [[String: Any]])?.first)
        #expect(idParameter["in"] as? String == "path")
        #expect((idParameter["schema"] as? [String: String])?["format"] == "uuid")
        let ok = try #require((show["responses"] as? [String: Any])?["200"] as? [String: Any])
        #expect("\(ok)".contains("#/components/schemas/Order"))

        let list = try #require(paths["/orders"]?["get"])
        let query = try #require(list["parameters"] as? [[String: Any]])
        #expect(query.map { $0["name"] as? String } == ["status", "page"])
        #expect(query.map { $0["required"] as? Bool } == [false, true])

        let create = try #require(paths["/orders"]?["post"])
        #expect(create["requestBody"] != nil)
        let createResponses = try #require(create["responses"] as? [String: Any])
        #expect(createResponses["422"] != nil, "a Validatable body declares its 422")
        #expect(createResponses["400"] != nil)

        let remove = try #require(paths["/orders/{id}"]?["delete"])
        #expect((remove["responses"] as? [String: Any])?["204"] != nil)

        let file = try #require(paths["/orders/files/{bucket}/{rest}"]?["get"])
        let names = (file["parameters"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(Set(names ?? []) == ["bucket", "rest"])
    }

    @Test("schemas: stored properties only, optionals not required, nested types, CodingKeys, enums")
    func schemas() throws {
        let document = try document()
        let schemas = try #require(
            (document["components"] as? [String: Any])?["schemas"] as? [String: [String: Any]])

        let order = try #require(schemas["Order"])
        let properties = try #require(order["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["id", "status", "lines", "note", "placedAt", "customer"])
        // An association: the value once loaded, null before; never required.
        #expect("\(properties["customer"] ?? "")".contains("#/components/schemas/Customer"))
        #expect("\(properties["customer"] ?? "")".contains("null"))
        #expect(Set(order["required"] as? [String] ?? []) == ["id", "status", "lines", "placedAt"])

        let status = try #require(schemas["Order_Status"])
        #expect(status["enum"] as? [String] == ["open", "SHIPPED"])

        let line = try #require(schemas["Order_Line"])
        #expect(Set((line["properties"] as? [String: Any])?.keys.map { $0 } ?? []) == ["item_sku", "quantity"])

        let newOrder = try #require(schemas["NewOrder"])
        let tags = try #require((newOrder["properties"] as? [String: Any])?["tags"] as? [String: Any])
        #expect(tags["type"] as? String == "object")
        #expect(tags["additionalProperties"] != nil)
    }

    @Test("no module takes a document: nothing is emitted")
    func onlyWhenAsked() throws {
        var sources = self.sources
        sources["Main.swift"] = """
            import AlulaWeb
            @main struct Main {
            static func main() async {
            await Alula.run(configuration: .load(), modules: [])
            }
            }
            """
        let result = try generator.generate(sources)
        #expect(!result.generated.contains("alulaOpenAPIJSON"))
    }
}
