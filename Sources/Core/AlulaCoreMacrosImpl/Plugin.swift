import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

@main
struct AlulaCoreMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ComponentMacro.self,
        ServiceMacro.self,
        RepositoryMacro.self,
        InjectMacro.self,
        ConfigValueMacro.self,
        SettingsMacro.self,
        SecretMacro.self,
    ]
}

/// Shared diagnostic shape. Every Alula macro diagnostic names the fix, not
/// just the problem — these fire at build time and are the first impression
/// of the compile-time-first pitch.
struct AlulaMacroDiagnostic: DiagnosticMessage {
    let message: String
    let id: String
    let severity: DiagnosticSeverity

    var diagnosticID: MessageID { MessageID(domain: "AlulaCoreMacros", id: id) }

    static func error(_ id: String, _ message: String) -> AlulaMacroDiagnostic {
        AlulaMacroDiagnostic(message: message, id: id, severity: .error)
    }
}

extension MacroExpansionContext {
    func diagnoseError(_ id: String, _ message: String, at node: some SyntaxProtocol) {
        diagnose(Diagnostic(node: Syntax(node), message: AlulaMacroDiagnostic.error(id, message)))
    }
}
