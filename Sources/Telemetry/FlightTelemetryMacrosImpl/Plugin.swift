import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

@main
struct FlightTelemetryMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        TelemetryEventMacro.self,
        TelemetrySpanMacro.self,
        TelemetryFieldsMacro.self,
        TelemetryMeasurementsMacro.self,
    ]
}

/// Same diagnostic discipline as the other macro modules: every diagnostic
/// names the fix, not just the problem.
struct TelemetryMacroDiagnostic: DiagnosticMessage {
    let message: String
    let id: String
    let severity: DiagnosticSeverity

    var diagnosticID: MessageID { MessageID(domain: "FlightTelemetryMacros", id: id) }
}

extension MacroExpansionContext {
    func diagnoseError(_ id: String, _ message: String, at node: some SyntaxProtocol) {
        diagnose(
            Diagnostic(
                node: Syntax(node),
                message: TelemetryMacroDiagnostic(message: message, id: id, severity: .error)))
    }

    /// Validation reports through this, so one check serves every role: the
    /// member role reports, and the extension role runs the same check
    /// silently — conforming an invalid declaration would bury the real
    /// diagnostic under "does not conform" errors.
    var report: Report { { id, message, node in self.diagnoseError(id, message, at: node) } }
}

typealias Report = (_ id: String, _ message: String, _ node: Syntax) -> Void

func silently(_ id: String, _ message: String, _ node: Syntax) {}

/// The access level generated members take: the declaration's own, so a
/// public event is usable from other modules and an internal one stays put.
func accessPrefix(of modifiers: DeclModifierListSyntax) -> String {
    // `public private(set) var` is public: a modifier with a detail
    // restricts the setter, not the declaration.
    for modifier in modifiers where modifier.detail == nil {
        switch modifier.name.tokenKind {
        case .keyword(.public), .keyword(.open): return "public "
        case .keyword(.package): return "package "
        default: continue
        }
    }
    return ""
}

/// The event name argument: a string literal that passes the grammar, or a
/// diagnostic saying why not.
func eventName(from node: AttributeSyntax, macro: String, report: Report) -> String? {
    guard case .argumentList(let arguments) = node.arguments,
        let first = arguments.first, first.label == nil
    else {
        report(
            "name.missing",
            "@\(macro) needs the event's name, such as @\(macro)(\"hangar.query\").",
            Syntax(node))
        return nil
    }
    guard let literal = first.expression.as(StringLiteralExprSyntax.self),
        literal.segments.count == 1,
        case .stringSegment(let segment) = literal.segments.first
    else {
        report(
            "name.notliteral",
            """
            @\(macro)'s name must be a plain string literal — it is checked here, at \
            build time, and it must be the same on every run.
            """,
            Syntax(first.expression))
        return nil
    }
    let name = segment.content.text
    guard EventNameGrammar.isValid(name) else {
        report(
            "name.grammar",
            """
            '\(name)' is not a valid event name: use lowercase segments separated by \
            dots, each starting with a letter, such as "hangar.query" or \
            "flight.sessions.created".
            """,
            Syntax(first.expression))
        return nil
    }
    return name
}

/// `EventName`'s grammar, again: the macro cannot link the runtime module.
/// `EventNameGrammarTests` holds the two to the same corpus.
enum EventNameGrammar {
    static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { segment in
            guard let first = segment.unicodeScalars.first, ("a"..."z").contains(first) else {
                return false
            }
            return segment.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
            }
        }
    }
}

/// The narrower of two access prefixes.
func narrowerAccess(_ a: String, _ b: String) -> String {
    let rank = ["": 0, "package ": 1, "public ": 2]
    return (rank[a] ?? 0) <= (rank[b] ?? 0) ? a : b
}
