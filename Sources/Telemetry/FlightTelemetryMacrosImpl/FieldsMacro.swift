import SwiftSyntax
import SwiftSyntaxMacros

/// `@TelemetryFields` — a struct's stored properties as event metadata.
///
/// Writes the `TelemetryFields` conformance: `encode(into:)`, one
/// `encoder.value` per stored property, and the key-path table metric
/// definitions read names from. On a public struct with no initializer of
/// its own it also writes a public memberwise one.
public struct TelemetryFieldsMacro: ExtensionMacro, MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        try FieldsExpansion.extensions(
            node: node, declaration: declaration, type: type, protocols: protocols,
            measurements: false, macro: "TelemetryFields", in: context)
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        FieldsExpansion.members(declaration: declaration, macro: "TelemetryFields", in: context)
    }
}

/// `@TelemetryMeasurements` — the same, as measurements: each stored property
/// is encoded with `encoder.measurement`, which requires a number or a
/// `Duration`. A string measurement is a compile error at the property,
/// not a surprise at a metric definition.
public struct TelemetryMeasurementsMacro: ExtensionMacro, MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        try FieldsExpansion.extensions(
            node: node, declaration: declaration, type: type, protocols: protocols,
            measurements: true, macro: "TelemetryMeasurements", in: context)
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        FieldsExpansion.members(declaration: declaration, macro: "TelemetryMeasurements", in: context)
    }
}

enum FieldsExpansion {
    static func extensions(
        node: AttributeSyntax,
        declaration: some DeclGroupSyntax,
        type: some TypeSyntaxProtocol,
        protocols: [TypeSyntax],
        measurements: Bool,
        macro: String,
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            context.diagnoseError(
                "fields.notstruct",
                """
                @\(macro) can only be attached to a struct: event fields are values, \
                copied to every handler.
                """,
                at: node)
            return []
        }
        // A hand-written conformance wins; the macro adds nothing to it.
        let handWritten = structDecl.memberBlock.members.contains {
            $0.decl.as(FunctionDeclSyntax.self)?.name.text == "encode"
        }
        guard !handWritten else { return [] }
        let (fields, computed) = FieldModel.fields(of: structDecl.memberBlock.members)
        if fields.isEmpty, computed > 0 {
            context.diagnoseError(
                "fields.computedonly",
                """
                \(structDecl.name.text) has only computed properties, and only stored \
                properties are encoded. Store the values the event carries.
                """,
                at: structDecl.name)
            return []
        }
        let access = accessPrefix(of: structDecl.modifiers)
        let conformance = protocols.isEmpty ? "" : ": FlightTelemetry.TelemetryFields"
        let members = FieldModel.conformanceMembers(fields, access: access, measurements: measurements)
        let body = members.map { $0.description }.joined(separator: "\n\n")
        return [
            try ExtensionDeclSyntax(
                """
                extension \(type.trimmed)\(raw: conformance) {
                \(raw: body)
                }
                """)
        ]
    }

    /// The public memberwise initializer, when the struct needs one and
    /// doesn't have one.
    static func members(
        declaration: some DeclGroupSyntax, macro: String, in context: some MacroExpansionContext
    ) -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else { return [] }
        let access = accessPrefix(of: structDecl.modifiers)
        guard !access.isEmpty else { return [] }
        let hasInit = structDecl.memberBlock.members.contains { $0.decl.is(InitializerDeclSyntax.self) }
        guard !hasInit else { return [] }
        let (fields, _) = FieldModel.fields(of: structDecl.memberBlock.members)
        // No wider than the narrowest field: an initializer cannot take a
        // parameter its callers could not see. At internal, Swift's own
        // memberwise initializer already does the job.
        let initAccess = fields.reduce(access) { narrowerAccess($0, $1.access) }
        guard !initAccess.isEmpty else { return [] }
        let untyped = fields.filter { $0.type == nil && !($0.isLet && $0.defaultValue != nil) }
        for field in untyped {
            context.diagnoseError(
                "fields.untyped",
                """
                Give '\(field.name)' an explicit type: @\(macro) writes \
                \(structDecl.name.text)'s \(initAccess)initializer, and an initializer parameter \
                needs one.
                """,
                at: field.node)
        }
        guard untyped.isEmpty else { return [] }
        return [FieldModel.memberwiseInit(fields, access: initAccess)]
    }
}
