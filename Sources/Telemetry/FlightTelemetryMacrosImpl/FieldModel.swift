import SwiftSyntax
import SwiftSyntaxMacros

/// One stored property of a fields struct.
struct Field {
    /// The Swift property name.
    let name: String
    /// The name handlers, metrics, and logs see: the property's, snake_cased.
    let key: String
    let type: TypeSyntax?
    let defaultValue: ExprSyntax?
    let isLet: Bool
    /// The property's own access, as a prefix: `"public "`, `"package "`,
    /// or `""` for internal and below.
    let access: String
    let node: Syntax
}

enum FieldModel {
    /// The stored instance properties of `decl`, in declaration order.
    /// Computed properties are not fields; `computedCount` reports how many
    /// were skipped so a struct of nothing but can be diagnosed.
    static func fields(of members: MemberBlockItemListSyntax) -> (fields: [Field], computedCount: Int) {
        var fields: [Field] = []
        var computed = 0
        for member in members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            if variable.modifiers.contains(where: {
                $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
            }) {
                continue
            }
            let isLet = variable.bindingSpecifier.tokenKind == .keyword(.let)
            let access = accessPrefix(of: variable.modifiers)
            let bindings = Array(variable.bindings)
            for (index, binding) in bindings.enumerated() {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                if let accessors = binding.accessorBlock, !isObserversOnly(accessors) {
                    computed += 1
                    continue
                }
                // `var a, b: Int` — `a` takes the type written after `b`.
                let type =
                    binding.typeAnnotation?.type
                    ?? bindings[(index + 1)...].lazy.compactMap { $0.typeAnnotation?.type }.first
                let name = pattern.identifier.text.trimmingBackticks
                fields.append(
                    Field(
                        name: name, key: snakeCase(name), type: type?.trimmed,
                        defaultValue: binding.initializer?.value.trimmed, isLet: isLet,
                        access: access, node: Syntax(binding)))
            }
        }
        return (fields, computed)
    }

    private static func isObserversOnly(_ block: AccessorBlockSyntax) -> Bool {
        guard case .accessors(let accessors) = block.accessors else { return false }
        return accessors.allSatisfy {
            $0.accessorSpecifier.tokenKind == .keyword(.willSet)
                || $0.accessorSpecifier.tokenKind == .keyword(.didSet)
        }
    }

    /// `errorType` → `error_type`, `requestURL` → `request_url`,
    /// `userID` → `user_id`: the convention every metrics and tracing
    /// backend expects for a label.
    static func snakeCase(_ name: String) -> String {
        let characters = Array(name)
        var result = ""
        for (index, character) in characters.enumerated() {
            if character.isUppercase, index > 0 {
                let previous = characters[index - 1]
                let nextIsLower = index + 1 < characters.count && characters[index + 1].isLowercase
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && nextIsLower) {
                    result.append("_")
                }
            }
            result.append(contentsOf: character.lowercased())
        }
        return result
    }

    /// `encode(into:)` and `fieldName(for:)`: the whole of a
    /// `TelemetryFields` conformance.
    static func conformanceMembers(
        _ fields: [Field], access: String, measurements: Bool
    ) -> [DeclSyntax] {
        let call = measurements ? "measurement" : "value"
        let encodeBody =
            fields.isEmpty
            ? "" : fields.map { "    encoder.\(call)(\"\($0.key)\", \($0.name))" }.joined(separator: "\n") + "\n"
        let nameBody =
            fields.isEmpty
            ? "    nil\n"
            : "    switch keyPath {\n"
                + fields.map { "    case \\Self.\($0.name): \"\($0.key)\"" }.joined(separator: "\n")
                + "\n    default: nil\n    }\n"
        return [
            """
            \(raw: access)func encode(into encoder: inout FlightTelemetry.FieldEncoder) {
            \(raw: encodeBody)}
            """,
            """
            \(raw: access)static func fieldName(for keyPath: PartialKeyPath<Self>) -> String? {
            \(raw: nameBody)}
            """,
        ]
    }

    /// A memberwise initializer at `access`. Swift synthesizes one only as
    /// `internal`, which leaves a public event's fields unconstructible
    /// outside its module.
    static func memberwiseInit(_ fields: [Field], access: String) -> DeclSyntax {
        let settable = fields.filter { !($0.isLet && $0.defaultValue != nil) }
        let parameters = settable.map { field -> String in
            let type = field.type.map { $0.description } ?? "_"
            let defaultValue = field.defaultValue.map { " = \($0)" } ?? ""
            return "\(field.name): \(type)\(defaultValue)"
        }.joined(separator: ", ")
        let body = settable.map { "    self.\($0.name) = \($0.name)" }.joined(separator: "\n")
        return """
            \(raw: access)init(\(raw: parameters)) {
            \(raw: body)
            }
            """
    }
}

extension String {
    var trimmingBackticks: String {
        hasPrefix("`") && hasSuffix("`") && count > 1 ? String(dropFirst().dropLast()) : self
    }
}
