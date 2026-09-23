import SwiftSyntax
import SwiftSyntaxMacros

/// `@TelemetrySpan("hangar.query")` — a caseless enum as a span.
///
/// ```swift
/// @TelemetrySpan("hangar.query", kind: .client)
/// public enum HangarQuery {
///     public struct Metadata { public var table: String }
///     public struct StopMetadata { public var rows: Int = 0 }
/// }
/// ```
///
/// Writes the `SpanEvent` conformance and three phase events, each a full
/// `TelemetryEvent` with its own name and handlers — `HangarQuery.Start`,
/// `.Stop`, and `.Exception`. The `stop` and `exception` phases carry flat
/// metadata: the span's fields, then (for `exception`) `errorType`, then
/// the stop fields, so a handler reads `metadata.table` and `metadata.rows`
/// alike.
public struct TelemetrySpanMacro: MemberMacro, MemberAttributeMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let plan = plan(node, declaration, report: context.report) else { return [] }
        let (enumDecl, name, metadata, stop) = (plan.enumDecl, plan.name, plan.metadata, plan.stop)
        let access = accessPrefix(of: enumDecl.modifiers)
        let spanFields = metadata.fields ?? []
        let stopFields = stop.fields ?? []

        let typeName = enumDecl.name.text
        var decls: [DeclSyntax] = [
            "\(raw: access)static let name: FlightTelemetry.EventName = \(literal: name)",
            "\(raw: access)static let _spanFlags = FlightTelemetry.SpanFlags(name: \(literal: name))",
        ]
        if let kind = kindArgument(of: node) {
            decls.append("\(raw: access)static var kind: FlightTelemetry.TelemetrySpanKind { \(raw: kind) }")
        }
        if metadata.fields == nil {
            decls.append("\(raw: access)typealias Metadata = FlightTelemetry.NoFields")
        }
        let stopType = stop.fields == nil ? "FlightTelemetry.NoFields" : "StopMetadata"

        decls.append(
            """
            \(raw: access)enum Start: FlightTelemetry.TelemetryEvent {
                \(raw: access)typealias Measurements = FlightTelemetry.SpanStartMeasurements
                \(raw: access)typealias Metadata = \(raw: typeName).Metadata
                \(raw: access)static let name: FlightTelemetry.EventName = \(literal: name + ".start")
                \(raw: access)static let _slot = FlightTelemetry.HandlerSlot<Start>(span: \(raw: typeName)._spanFlags, phase: .start)
            }
            """)
        decls.append(
            phase(
                "Stop", name: name + ".stop", access: access, owner: typeName,
                fields: spanFields + stopFields))
        let errorType = Field(
            name: "errorType", key: "error_type", type: "String", defaultValue: nil, isLet: true,
            access: access, node: Syntax(node))
        decls.append(
            phase(
                "Exception", name: name + ".exception", access: access, owner: typeName,
                fields: spanFields + [errorType] + stopFields))

        if stop.fields != nil {
            decls.append(
                "\(raw: access)static func initialStopMetadata() -> StopMetadata { StopMetadata() }")
        }
        let copy = { (fields: [Field], from: String) in
            fields.map { "\($0.name): \(from).\($0.name)" }
        }
        let stopArguments = (copy(spanFields, "metadata") + copy(stopFields, "stop")).joined(separator: ", ")
        decls.append(
            """
            \(raw: access)static func stopMetadata(_ metadata: Metadata, _ stop: \(raw: stopType)) -> Stop.Metadata {
                Stop.Metadata(\(raw: stopArguments))
            }
            """)
        let exceptionArguments =
            (copy(spanFields, "metadata") + ["errorType: errorType"] + copy(stopFields, "stop"))
            .joined(separator: ", ")
        decls.append(
            """
            \(raw: access)static func exceptionMetadata(_ metadata: Metadata, _ stop: \(raw: stopType), errorType: String) -> Exception.Metadata {
                Exception.Metadata(\(raw: exceptionArguments))
            }
            """)
        return decls
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        EventShape.fieldAttributes(for: member, measurements: [], metadata: ["Metadata", "StopMetadata"])
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard !protocols.isEmpty, plan(node, declaration, report: silently) != nil else { return [] }
        return [try ExtensionDeclSyntax("extension \(type.trimmed): FlightTelemetry.SpanEvent {}")]
    }

    /// A phase event whose metadata is `fields`, flattened into one struct
    /// of `let`s — handlers only read them.
    private static func phase(
        _ phase: String, name: String, access: String, owner: String, fields: [Field]
    ) -> DeclSyntax {
        // Each field keeps its own access: a public phase event may carry an
        // internal field, which stays internal here too.
        let properties = fields.map {
            "        \(narrowerAccess(access, $0.access))let \($0.name): \($0.type!.description)"
        }
        let members = FieldModel.conformanceMembers(fields, access: access, measurements: false)
            .map { $0.description.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "        " + $0 }.joined(separator: "\n") }
        let body = (properties + members).joined(separator: "\n")
        return """
            \(raw: access)enum \(raw: phase): FlightTelemetry.TelemetryEvent {
                \(raw: access)typealias Measurements = FlightTelemetry.SpanDurationMeasurements
                \(raw: access)struct Metadata: FlightTelemetry.TelemetryFields {
            \(raw: body)
                }
                \(raw: access)static let name: FlightTelemetry.EventName = \(literal: name)
                \(raw: access)static let _slot = FlightTelemetry.HandlerSlot<\(raw: phase)>(span: \(raw: owner)._spanFlags, phase: .\(raw: phase.lowercased()))
            }
            """
    }

    private struct Plan {
        let enumDecl: EnumDeclSyntax
        let name: String
        let metadata: SpanFields
        let stop: SpanFields
    }

    /// Everything the expansion needs, once the declaration is known to be
    /// a valid span; `nil` after reporting why not.
    private static func plan(
        _ node: AttributeSyntax, _ declaration: some DeclGroupSyntax, report: Report
    ) -> Plan? {
        guard let enumDecl = EventShape.validate(node, declaration, macro: "TelemetrySpan", report: report),
            let name = eventName(from: node, macro: "TelemetrySpan", report: report)
        else { return nil }
        let members = enumDecl.memberBlock.members
        guard let metadata = spanFields(named: "Metadata", in: members, report: report),
            let stop = spanFields(named: "StopMetadata", in: members, report: report)
        else { return nil }

        var valid = true
        if let stopFields = stop.fields {
            for field in stopFields where field.defaultValue == nil {
                report(
                    "span.stopdefault",
                    """
                    Give '\(field.name)' a default value: StopMetadata exists before the \
                    body sets anything, and a span that stops early reports the defaults.
                    """,
                    Syntax(field.node))
                valid = false
            }
        }
        let spanFields = metadata.fields ?? []
        let stopFields = stop.fields ?? []
        let seen = Dictionary(grouping: spanFields + stopFields, by: \.name)
        for field in stopFields where (seen[field.name]?.count ?? 0) > 1 {
            report(
                "span.fieldclash",
                """
                '\(field.name)' is in both Metadata and StopMetadata, and the stop phase \
                carries both flattened into one. Rename one of them.
                """,
                Syntax(field.node))
            valid = false
        }
        for field in spanFields + stopFields where field.name == "errorType" {
            report(
                "span.errortype",
                """
                'errorType' is the name the exception phase gives the error's type. \
                Rename this field.
                """,
                Syntax(field.node))
            valid = false
        }
        guard valid else { return nil }
        return Plan(enumDecl: enumDecl, name: name, metadata: metadata, stop: stop)

    }

    /// A nested fields struct, as the span sees it.
    private struct SpanFields {
        /// `nil` when the struct is left out.
        let fields: [Field]?
    }

    /// A nested fields struct's stored properties; `nil` after a diagnostic.
    private static func spanFields(
        named name: String, in members: MemberBlockItemListSyntax, report: Report
    ) -> SpanFields? {
        guard
            let structDecl = members.lazy.compactMap({ $0.decl.as(StructDeclSyntax.self) })
                .first(where: { $0.name.text == name })
        else { return SpanFields(fields: nil) }
        let (fields, _) = FieldModel.fields(of: structDecl.memberBlock.members)
        var valid = true
        for field in fields where field.type == nil {
            report(
                "span.untyped",
                """
                Give '\(field.name)' an explicit type: @TelemetrySpan copies it into the \
                stop and exception metadata.
                """,
                Syntax(field.node))
            valid = false
        }
        return valid ? SpanFields(fields: fields) : nil
    }

    private static func kindArgument(of node: AttributeSyntax) -> String? {
        guard case .argumentList(let arguments) = node.arguments else { return nil }
        return arguments.first { $0.label?.text == "kind" }?.expression.trimmedDescription
    }
}
