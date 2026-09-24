#if Web
import AlulaConfigCore
import AlulaCore
@testable import AlulaOpenAPI
import AlulaWeb
import AlulaWebTesting
import Foundation
import Testing

@Suite("OpenAPI module")
struct OpenAPIModuleTests {
    let document = OpenAPIDocument(generatedJSON: #"{"paths":{"/x":{"get":{"responses":{"204":{"description":"No Content"}}}}},"components":{}}"#)

    private func configuration(_ values: [String: String], _ environment: AlulaEnvironment) -> Configuration {
        Configuration(sources: [TestConfigSource(values)], environment: environment)
    }

    @Test("serves the document with openapi and info added")
    func serves() async throws {
        let module = try AlulaOpenAPIModule(
            configuration: configuration(["app.name": "Orders", "openapi.version": "1.2.0"], .dev),
            document: document)
        let response = await try TestClient(routes: module.routes).get("/openapi.json")
        #expect(response.status == .ok)
        let body = try #require(try JSONSerialization.jsonObject(with: response.bodyData ?? Data()) as? [String: Any])
        #expect(body["openapi"] as? String == "3.1.0")
        let info = try #require(body["info"] as? [String: String])
        #expect(info == ["title": "Orders", "version": "1.2.0"])
        #expect((body["paths"] as? [String: Any])?["/x"] != nil)
    }

    @Test("snake-case keys are renamed the way Foundation's encoder renames them")
    func snakeCase() throws {
        for (key, expected) in [
            ("placedAt", "placed_at"), ("myURLProperty", "my_url_property"), ("id", "id"),
            ("userID", "user_id"), ("already_snake", "already_snake"),
        ] {
            // Foundation's own answer is the specification.
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            struct Key: Encodable {
                let key: String
                func encode(to encoder: any Encoder) throws {
                    var container = encoder.container(keyedBy: Dynamic.self)
                    try container.encode(1, forKey: Dynamic(stringValue: key)!)
                }
                struct Dynamic: CodingKey {
                    var stringValue: String
                    init?(stringValue: String) { self.stringValue = stringValue }
                    var intValue: Int? { nil }
                    init?(intValue: Int) { nil }
                }
            }
            let foundation = String(decoding: try encoder.encode(Key(key: key)), as: UTF8.self)
            #expect(foundation == "{\"\(expected)\":1}", "\(key)")
            #expect(OpenAPIDocument.snakeCased(key) == expected, "\(key)")
        }
    }

    @Test("off outside development unless enabled; the path is configurable")
    func exposure() throws {
        #expect(try AlulaOpenAPIModule(configuration: configuration([:], .prod), document: document).routes.isEmpty)
        let enabled = try AlulaOpenAPIModule(
            configuration: configuration(["openapi.enabled": "true", "openapi.path": "/docs/api.json"], .prod),
            document: document)
        #expect(enabled.routes.map(\.path) == ["/docs/api.json"])
    }
}
#endif
