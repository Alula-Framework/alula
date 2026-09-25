import Foundation
import SwiftSyntax

// OpenAPI 3.1 from what the build already scans: every route's method, path,
// typed path parameters, `query:` and `body:` types and return type, and the
// stored properties of the types they name. Emitted as a JSON literal only
// when an included module takes an `OpenAPIDocument`.

/// A type as far as its JSON shape goes.
struct SchemaDecl {
    enum Shape {
        /// Stored properties, in declaration order: JSON key, type text.
        case object([(key: String, typeText: String)])
        case stringEnum([String])
        case integerEnum
    }
    let name: String
    let shape: Shape
    let conformances: [String]
}

/// Collects struct, class and enum shapes, nested ones as `Outer.Inner`.
final class SchemaCollector: SyntaxVisitor {
    private(set) var types: [SchemaDecl] = []
    private var stack: [String] = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, members: node.memberBlock, inheritance: node.inheritanceClause)
        stack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { stack.removeLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, members: node.memberBlock, inheritance: node.inheritanceClause)
        stack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { stack.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let inherited = node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        let name = (stack + [node.name.text]).joined(separator: ".")
        var cases: [String] = []
        var hasPayload = false
        for member in node.memberBlock.members {
            guard let decl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in decl.elements {
                if element.parameterClause != nil { hasPayload = true }
                if let raw = element.rawValue?.value.as(StringLiteralExprSyntax.self) {
                    cases.append(raw.segments.trimmedDescription)
                } else {
                    cases.append(element.name.text)
                }
            }
        }
        if !hasPayload, node.name.text != "CodingKeys" {
            if inherited.first == "String" {
                types.append(SchemaDecl(name: name, shape: .stringEnum(cases), conformances: inherited))
            } else if ["Int", "Int32", "Int64", "UInt"].contains(inherited.first ?? "") {
                types.append(SchemaDecl(name: name, shape: .integerEnum, conformances: inherited))
            }
        }
        stack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { stack.removeLast() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

    private func record(_ simpleName: String, members: MemberBlockSyntax, inheritance: InheritanceClauseSyntax?) {
        let name = (stack + [simpleName]).joined(separator: ".")
        let conformances = inheritance?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        // CodingKeys renames, when the type declares them.
        var renamed: [String: String] = [:]
        var keyed: Set<String>? = nil
        for member in members.members {
            guard let keys = member.decl.as(EnumDeclSyntax.self), keys.name.text == "CodingKeys" else { continue }
            keyed = []
            for case let decl? in keys.memberBlock.members.map({ $0.decl.as(EnumCaseDeclSyntax.self) }) {
                for element in decl.elements {
                    keyed?.insert(element.name.text)
                    if let raw = element.rawValue?.value.as(StringLiteralExprSyntax.self) {
                        renamed[element.name.text] = raw.segments.trimmedDescription
                    }
                }
            }
        }
        var properties: [(String, String)] = []
        for member in members.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            if variable.modifiers.contains(where: { ["static", "class", "lazy"].contains($0.name.text) }) { continue }
            for binding in variable.bindings {
                // Computed properties are not encoded; observed ones are.
                if let accessors = binding.accessorBlock {
                    let isObserved = accessors.accessors.as(AccessorDeclListSyntax.self)?.allSatisfy {
                        ["willSet", "didSet"].contains($0.accessorSpecifier.text)
                    } ?? false
                    if !isObserved { continue }
                }
                guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
                      let type = binding.typeAnnotation?.type.trimmedDescription
                else { continue }
                let property = identifier.identifier.text
                if let keyed, !keyed.contains(property) { continue }
                properties.append((renamed[property] ?? property, type))
            }
        }
        types.append(SchemaDecl(name: name, shape: .object(properties), conformances: conformances))
    }
}

/// Builds the document's `paths` and `components` as JSON text.
final class OpenAPIBuilder {
    let routes: [ScannedControllerRoute]
    let types: [SchemaDecl]

    /// What the document could not describe, for the build to report.
    struct Gap {
        enum Kind {
            /// A type no scanned target declares; `via` is the property
            /// path from the route's own type, when it is nested.
            case unknownType(String, via: String?)
            case untypedResponse
        }
        let route: ScannedControllerRoute
        let kind: Kind
    }
    private(set) var gaps: [Gap] = []
    /// The route and property being described, so a gap can say where.
    private var currentRoute: ScannedControllerRoute?
    private var currentVia: String?
    /// The route that first referenced each component.
    private var origin: [String: ScannedControllerRoute] = [:]
    private var reportedTypes: Set<String> = []

    init(routes: [ScannedControllerRoute], types: [SchemaDecl]) {
        self.routes = routes
        self.types = types
    }

    private var byName: [String: SchemaDecl] {
        var map: [String: SchemaDecl] = [:]
        for type in types {
            map[type.name] = map[type.name] ?? type
            let last = String(type.name.split(separator: ".").last ?? "")
            if map[last] == nil { map[last] = type }
        }
        return map
    }

    func json() -> String {
        var referenced: Set<String> = []
        var paths: [String: [String: Any]] = [:]
        for route in routes where !route.isUpgrade {
            currentRoute = route
            currentVia = nil
            var operation: [String: Any] = [
                "operationId": "\(route.controllerTypeName).\(route.methodName)",
                "tags": [route.controllerTypeName],
            ]
            var parameters: [[String: Any]] = []
            for parameter in route.pathParameters {
                parameters.append([
                    "name": parameter.name, "in": "path", "required": true,
                    "schema": schema(parameter.typeText, &referenced),
                ])
            }
            if let query = route.queryTypeText, let decl = byName[query], case .object(let properties) = decl.shape {
                for property in properties {
                    let (inner, optional) = unwrapOptional(property.typeText)
                    parameters.append([
                        "name": property.key, "in": "query", "required": !optional,
                        "schema": schema(inner, &referenced),
                    ])
                }
            }
            // A `:segment` the handler reads from the context rather than its
            // signature: a template parameter must still be declared.
            let bound = Set(route.pathParameters.map(\.name))
            for segment in route.path.split(separator: "/") where segment.hasPrefix(":") {
                let name = String(segment.dropFirst())
                guard !bound.contains(name) else { continue }
                parameters.append([
                    "name": name, "in": "path", "required": true, "schema": ["type": "string"],
                ])
            }
            if route.path.hasSuffix("/**") || route.path == "**" {
                parameters.append([
                    "name": "rest", "in": "path", "required": true,
                    "schema": ["type": "string"],
                    "description": "The rest of the path, slashes included.",
                ])
            }
            if !parameters.isEmpty { operation["parameters"] = parameters }

            var responses: [String: Any] = [:]
            if let body = route.bodyTypeText, body != "RequestBodyStream", body != "AlulaWeb.RequestBodyStream" {
                let content: [String: Any]
                switch body {
                case "String": content = ["text/plain": ["schema": ["type": "string"]]]
                case "Data", "Foundation.Data":
                    content = ["application/octet-stream": ["schema": ["type": "string", "format": "binary"]]]
                default: content = ["application/json": ["schema": schema(body, &referenced)]]
                }
                operation["requestBody"] = ["required": true, "content": content]
                responses["400"] = ["$ref": "#/components/responses/Problem"]
                if byName[body]?.conformances.contains("Validatable") == true {
                    responses["422"] = ["$ref": "#/components/responses/ValidationProblem"]
                }
            }
            if let query = route.queryTypeText {
                responses["400"] = ["$ref": "#/components/responses/Problem"]
                if byName[query]?.conformances.contains("Validatable") == true {
                    responses["422"] = ["$ref": "#/components/responses/ValidationProblem"]
                }
            }
            switch route.returnTypeText.map(stripped) {
            case nil, "Void", "()":
                responses["204"] = ["description": "No Content"]
            case "Response", "AlulaWeb.Response":
                responses["default"] = ["description": "Response"]
                if !route.acknowledgesUndocumentedResponse {
                    gaps.append(Gap(route: route, kind: .untypedResponse))
                }
            case "String":
                responses["200"] = ["description": "OK", "content": ["text/plain": ["schema": ["type": "string"]]]]
            case let type?:
                responses["200"] = [
                    "description": "OK", "content": ["application/json": ["schema": schema(type, &referenced)]],
                ]
            }
            operation["responses"] = responses
            paths[openAPIPath(route.path), default: [:]][route.httpMethod.lowercased()] = operation
        }

        // Every type reachable from a referenced one.
        var schemas: [String: Any] = [:]
        var queue = Array(referenced)
        var done: Set<String> = []
        while let name = queue.popLast() {
            guard done.insert(name).inserted, let decl = byName[name] else { continue }
            currentRoute = origin[name]
            var nested: Set<String> = []
            schemas[componentName(name)] = component(decl, &nested)
            queue += nested.subtracting(done)
        }
        let problem: [String: Any] = [
            "type": "object",
            "properties": ["status": ["type": "integer"], "title": ["type": "string"], "detail": ["type": "string"]],
        ]
        var validation = problem
        validation["properties"] = [
            "status": ["type": "integer"], "title": ["type": "string"], "detail": ["type": "string"],
            "errors": [
                "type": "array",
                "items": [
                    "type": "object", "required": ["field", "message"],
                    "properties": ["field": ["type": "string"], "message": ["type": "string"]],
                ],
            ],
        ]
        let document: [String: Any] = [
            "paths": paths,
            "components": [
                "schemas": schemas,
                "responses": [
                    "Problem": ["description": "Bad request", "content": ["application/problem+json": ["schema": problem]]],
                    "ValidationProblem": [
                        "description": "Validation failed", "content": ["application/problem+json": ["schema": validation]],
                    ],
                ],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func component(_ decl: SchemaDecl, _ referenced: inout Set<String>) -> [String: Any] {
        switch decl.shape {
        case .stringEnum(let cases): return ["type": "string", "enum": cases]
        case .integerEnum: return ["type": "integer"]
        case .object(let properties):
            var fields: [String: Any] = [:]
            var required: [String] = []
            for property in properties {
                let (inner, optional) = unwrapOptional(property.typeText)
                currentVia = "\(decl.name).\(property.key)"
                fields[property.key] = schema(inner, &referenced)
                if !optional { required.append(property.key) }
            }
            var result: [String: Any] = ["type": "object", "properties": fields]
            if !required.isEmpty { result["required"] = required }
            return result
        }
    }

    /// A type's schema, recording named types it refers to.
    private func schema(_ typeText: String, _ referenced: inout Set<String>) -> [String: Any] {
        let type = stripped(typeText)
        // Hangar's association wrapper: the value when loaded, `null` when not.
        if type.hasPrefix("Loadable<"), type.hasSuffix(">") {
            let wrapped = String(type.dropFirst("Loadable<".count).dropLast())
            return ["anyOf": [schema(wrapped, &referenced), ["type": "null"]]]
        }
        let (inner, optional) = unwrapOptional(type)
        if optional { return schema(inner, &referenced) }
        if type.hasPrefix("["), type.hasSuffix("]") {
            let body = String(type.dropFirst().dropLast())
            if let colon = topLevelColon(body) {
                let value = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                return ["type": "object", "additionalProperties": schema(value, &referenced)]
            }
            return ["type": "array", "items": schema(body, &referenced)]
        }
        if type.hasPrefix("Array<"), type.hasSuffix(">") {
            return ["type": "array", "items": schema(String(type.dropFirst(6).dropLast()), &referenced)]
        }
        switch type {
        case "String", "Substring", "Character": return ["type": "string"]
        case "Int", "UInt", "Int64", "UInt64": return ["type": "integer", "format": "int64"]
        case "Int32", "UInt32", "Int16", "UInt16", "Int8", "UInt8": return ["type": "integer", "format": "int32"]
        case "Double", "CGFloat": return ["type": "number", "format": "double"]
        case "Float": return ["type": "number", "format": "float"]
        case "Decimal": return ["type": "number"]
        case "Bool": return ["type": "boolean"]
        case "UUID", "Foundation.UUID": return ["type": "string", "format": "uuid"]
        case "Date", "Foundation.Date": return ["type": "string", "format": "date-time"]
        case "URL", "Foundation.URL": return ["type": "string", "format": "uri"]
        case "Data", "Foundation.Data": return ["type": "string", "format": "byte"]
        default:
            guard let decl = byName[type] else {
                if let route = currentRoute, reportedTypes.insert(type).inserted {
                    gaps.append(Gap(route: route, kind: .unknownType(type, via: currentVia)))
                }
                return ["description": "\(type): not declared in a scanned target"]
            }
            if origin[decl.name] == nil, let route = currentRoute { origin[decl.name] = route }
            referenced.insert(decl.name)
            return ["$ref": "#/components/schemas/\(componentName(decl.name))"]
        }
    }

    private func componentName(_ name: String) -> String {
        name.replacingOccurrences(of: ".", with: "_")
    }

    private func unwrapOptional(_ typeText: String) -> (String, Bool) {
        let type = stripped(typeText)
        if type.hasSuffix("?") { return (String(type.dropLast()), true) }
        if type.hasPrefix("Optional<"), type.hasSuffix(">") { return (String(type.dropFirst(9).dropLast()), true) }
        // Present as `null` until loaded: never required.
        if type.hasPrefix("Loadable<") { return (type, true) }
        return (type, false)
    }

    private func stripped(_ typeText: String) -> String {
        typeText.trimmingCharacters(in: .whitespaces)
    }

    private func topLevelColon(_ text: String) -> String.Index? {
        var depth = 0
        for index in text.indices {
            switch text[index] {
            case "[", "<", "(": depth += 1
            case "]", ">", ")": depth -= 1
            case ":" where depth == 0: return index
            default: break
            }
        }
        return nil
    }

    /// `/users/:id/**` → `/users/{id}/{rest}`.
    private func openAPIPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
            if segment.hasPrefix(":") { return "{\(segment.dropFirst())}" }
            if segment == "**" { return "{rest}" }
            return String(segment)
        }.joined(separator: "/")
    }
}
