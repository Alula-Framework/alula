import AlulaCore
import AlulaWeb
import Foundation
import HTTPTypes

/// The OpenAPI description the build derived from this application's routes
/// and the types they take and return. The composition root supplies it. An
/// application never builds one.
public struct OpenAPIDocument: Sendable {
    /// `paths` and `components`, as the build plugin wrote them.
    public let generatedJSON: String

    public init(generatedJSON: String) {
        self.generatedJSON = generatedJSON
    }

    /// The full document: `openapi`, `info`, then the generated parts.
    ///
    /// - Parameter snakeCaseKeys: Rename schema properties the way
    ///   `web.json.key-strategy: snake-case` renames them on the wire.
    public func rendered(
        title: String, version: String, description: String? = nil, snakeCaseKeys: Bool = false
    ) throws -> Data {
        var document =
            (try JSONSerialization.jsonObject(with: Data(generatedJSON.utf8)) as? [String: Any]) ?? [:]
        if snakeCaseKeys, var components = document["components"] as? [String: Any],
            let schemas = components["schemas"] as? [String: Any]
        {
            components["schemas"] = schemas.mapValues { schema -> Any in
                guard var object = schema as? [String: Any] else { return schema }
                if let properties = object["properties"] as? [String: Any] {
                    object["properties"] = Dictionary(
                        properties.map { (Self.snakeCased($0.key), $0.value) },
                        uniquingKeysWith: { first, _ in first })
                }
                if let required = object["required"] as? [String] {
                    object["required"] = required.map(Self.snakeCased)
                }
                return object
            }
            document["components"] = components
        }
        var info: [String: Any] = ["title": title, "version": version]
        if let description { info["description"] = description }
        document["openapi"] = "3.1.0"
        document["info"] = info
        return try JSONSerialization.data(
            withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Foundation's `convertToSnakeCase`: a word boundary before an upper-case
    /// letter that follows a lower-case one, and before the last capital of a
    /// run followed by a lower-case letter. So `myURLProperty` becomes
    /// `my_url_property`.
    static func snakeCased(_ key: String) -> String {
        let characters = Array(key)
        guard !characters.isEmpty else { return key }
        var words: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            if character.isUppercase, !current.isEmpty {
                let previous = characters[index - 1]
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if previous.isLowercase || previous.isNumber || (next?.isLowercase ?? false) && previous.isUppercase {
                    words.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        words.append(current)
        return words.map { $0.lowercased() }.joined(separator: "_")
    }
}

/// Serves the application's OpenAPI 3.1 document, generated at build time
/// from the same route scan the route table comes from:
///
/// ```yaml
/// openapi:
///   path: /openapi.json       # default
///   title: Orders API         # default: app.name
///   version: 1.4.0            # default: 0.0.0
///   enabled: true             # default: only in dev and test
/// ```
///
/// What the document knows comes from source:
/// - every `@Controller` route (not WebSocket upgrades);
/// - typed path parameters, `query:` struct fields and `body:` types;
/// - return types;
/// - the stored properties of the types those name, `CodingKeys` renames
///   included.
///
/// `Validatable` bodies declare the 422 they can answer. A handler returning
/// `Response` is described as returning "a response", because the build
/// cannot see what it will contain.
///
/// Off outside development unless `openapi.enabled: true`. A description of
/// every route and payload is useful to clients, and just as useful to anyone
/// probing the service. Publishing it is a decision.
public struct AlulaOpenAPIModule: AlulaModule {
    public let routes: [RouteRegistration]

    public init(configuration: Configuration, document: OpenAPIDocument) throws {
        let environment = configuration.environment ?? AlulaEnvironment.current()
        let enabled =
            try configuration.getIfPresent("openapi.enabled", as: Bool.self)
            ?? (environment == .dev || environment == .test)
        guard enabled else {
            self.routes = []
            return
        }
        let path = try configuration.getIfPresent("openapi.path", as: String.self) ?? "/openapi.json"
        let title =
            try configuration.getIfPresent("openapi.title", as: String.self)
            ?? configuration.getIfPresent("app.name", as: String.self) ?? "API"
        let version = try configuration.getIfPresent("openapi.version", as: String.self) ?? "0.0.0"
        let description = try configuration.getIfPresent("openapi.description", as: String.self)
        let snakeCase =
            try configuration.getIfPresent("web.json.key-strategy", as: String.self) == "snake-case"
        let body = try document.rendered(
            title: title, version: version, description: description, snakeCaseKeys: snakeCase)
        self.routes = [
            RouteRegistration(method: .get, path: path, source: "AlulaOpenAPI") { _ in
                .data(body, contentType: .json)
            }
        ]
    }

    public init() {
        preconditionFailure(
            "AlulaOpenAPIModule takes its configuration and the generated document in "
                + "init(configuration:document:), so it cannot be instantiated from its type. "
                + "Pass `composedBy: alulaComposeModules` to Alula.run.")
    }
}
