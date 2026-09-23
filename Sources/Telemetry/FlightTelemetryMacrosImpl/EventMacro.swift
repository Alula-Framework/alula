import SwiftSyntax
import SwiftSyntaxMacros

/// `@TelemetryEvent("hangar.query")` — a caseless enum as an event type.
///
/// Writes `name` and the handler slot, conforms the enum, and marks its
/// nested `Measurements` and `Metadata` structs so they encode themselves.
/// Either struct may be left out; its associated type is then `NoFields`.
public struct TelemetryEventMacro: MemberMacro, MemberAttributeMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let enumDecl = EventShape.validate(node, declaration, macro: "TelemetryEvent", report: context.report),
            let name = eventName(from: node, macro: "TelemetryEvent", report: context.report)
        else { return [] }
        let access = accessPrefix(of: enumDecl.modifiers)
        return [
            "\(raw: access)static let name: FlightTelemetry.EventName = \(literal: name)",
            "\(raw: access)static let _slot = FlightTelemetry.HandlerSlot<\(raw: enumDecl.name.text)>()",
        ]
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        EventShape.fieldAttributes(
            for: member, measurements: ["Measurements"], metadata: ["Metadata"])
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard !protocols.isEmpty,
            EventShape.validate(node, declaration, macro: "TelemetryEvent", report: silently) != nil,
            eventName(from: node, macro: "TelemetryEvent", report: silently) != nil
        else { return [] }
        return [try ExtensionDeclSyntax("extension \(type.trimmed): FlightTelemetry.TelemetryEvent {}")]
    }
}

/// What `@TelemetryEvent` and `@TelemetrySpan` share: the shape they accept
/// and the attributes they put on nested field structs.
enum EventShape {
    /// The enum, when the declaration is a caseless, non-generic one whose
    /// nested field types are structs; `nil` after diagnosing otherwise.
    static func validate(
        _ node: AttributeSyntax, _ declaration: some DeclGroupSyntax, macro: String, report: Report
    ) -> EnumDeclSyntax? {
        guard let enumDecl = declaration.as(EnumDeclSyntax.self) else {
            report(
                "event.notenum",
                """
                @\(macro) can only be attached to an enum with no cases — the type is \
                the event's name, and is never instantiated. Write 'enum' here.
                """,
                Syntax(node))
            return nil
        }
        if let caseDecl = enumDecl.memberBlock.members.lazy.compactMap({
            $0.decl.as(EnumCaseDeclSyntax.self)
        }).first {
            report(
                "event.hascases",
                """
                An @\(macro) enum has no cases — the type is the event's name, and is \
                never instantiated. Carry these values as Metadata fields instead.
                """,
                Syntax(caseDecl))
            return nil
        }
        if let generics = enumDecl.genericParameterClause {
            report(
                "event.generic",
                """
                An @\(macro) enum cannot be generic: each event type has one name and \
                one set of handlers, stored statically.
                """,
                Syntax(generics))
            return nil
        }
        var valid = true
        for member in enumDecl.memberBlock.members {
            guard let classDecl = member.decl.as(ClassDeclSyntax.self),
                fieldTypeNames.contains(classDecl.name.text)
            else { continue }
            report(
                "event.classfields",
                """
                \(classDecl.name.text) must be a struct: event fields are values, copied \
                to every handler and across threads.
                """,
                Syntax(classDecl.classKeyword))
            valid = false
        }
        return valid ? enumDecl : nil
    }

    static let fieldTypeNames: Set<String> = ["Measurements", "Metadata", "StopMetadata"]

    /// `@TelemetryMeasurements` or `@TelemetryFields` for a nested struct
    /// with one of the conventional names, unless it already has one or
    /// conforms by hand.
    static func fieldAttributes(
        for member: some DeclSyntaxProtocol, measurements: Set<String>, metadata: Set<String>
    ) -> [AttributeSyntax] {
        guard let structDecl = member.as(StructDeclSyntax.self) else { return [] }
        let name = structDecl.name.text
        let attribute: String
        if measurements.contains(name) {
            attribute = "TelemetryMeasurements"
        } else if metadata.contains(name) {
            attribute = "TelemetryFields"
        } else {
            return []
        }
        let alreadyMarked = structDecl.attributes.contains {
            guard let existing = $0.as(AttributeSyntax.self) else { return false }
            let text = existing.attributeName.trimmedDescription
            return text.hasSuffix("TelemetryFields") || text.hasSuffix("TelemetryMeasurements")
        }
        let conformsByHand =
            structDecl.inheritanceClause?.inheritedTypes.contains {
                $0.type.trimmedDescription.hasSuffix("TelemetryFields")
            } ?? false
        guard !alreadyMarked, !conformsByHand else { return [] }
        return [AttributeSyntax(attributeName: IdentifierTypeSyntax(name: .identifier(attribute)))]
    }
}
