import AlulaDiagnostics
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// A macro diagnostic carrying an Alula diagnostic code.
///
/// The code decides the severity, so a call site cannot report as an error
/// what the code's page calls a warning. The message leads with the code —
/// `[ALU-WEB-2004] @GetRoute path 'users' must start with '/'.` — which is
/// what a reader searches for, and what `alula explain` takes.
public struct CodedMacroMessage: DiagnosticMessage {
    public let code: DiagnosticCode
    public let text: String

    public var message: String { "[\(code.id)] \(text)" }
    public var diagnosticID: MessageID { MessageID(domain: "Alula", id: code.id) }
    public var severity: DiagnosticSeverity {
        switch code.severity {
        case .error: .error
        case .warning: .warning
        case .note: .note
        }
    }
}

/// The note under every coded macro diagnostic: where its page is.
struct DocumentationNote: NoteMessage {
    let code: DiagnosticCode
    var message: String { "see \(code.documentationURL)" }
    var noteID: MessageID { MessageID(domain: "Alula", id: "\(code.id).docs") }
}

/// A fix-it's label.
public struct AlulaFixItMessage: FixItMessage {
    public let message: String
    public var fixItID: MessageID { MessageID(domain: "Alula", id: message) }

    public init(_ message: String) { self.message = message }
}

extension MacroExpansionContext {
    /// Reports `code` at `node`, with a note linking the code's page.
    public func diagnose(
        _ code: DiagnosticCode, _ message: String, at node: some SyntaxProtocol,
        fixIts: [FixIt] = []
    ) {
        diagnose(
            SwiftDiagnostics.Diagnostic(
                node: Syntax(node),
                message: CodedMacroMessage(code: code, text: message),
                notes: [Note(node: Syntax(node), message: DocumentationNote(code: code))],
                fixIts: fixIts))
    }
}

extension FixIt {
    /// Adds `final` to a class declaration — the unambiguous fix for an
    /// attribute that accepts a struct or a final class.
    public static func insertFinal(into classDecl: ClassDeclSyntax) -> FixIt {
        var modifiers = classDecl.modifiers
        var classKeyword = classDecl.classKeyword
        // `final` goes after any existing modifiers (`public final class`),
        // and takes the keyword's leading trivia when it becomes the first
        // token after the attributes.
        let final = DeclModifierSyntax(
            leadingTrivia: modifiers.isEmpty ? classKeyword.leadingTrivia : [],
            name: .keyword(.final), trailingTrivia: .space)
        if modifiers.isEmpty { classKeyword.leadingTrivia = [] }
        modifiers.append(final)
        return FixIt(
            message: AlulaFixItMessage("mark the class 'final'"),
            changes: [
                .replace(
                    oldNode: Syntax(classDecl),
                    newNode: Syntax(classDecl.with(\.modifiers, modifiers).with(\.classKeyword, classKeyword)))
            ])
    }
}
