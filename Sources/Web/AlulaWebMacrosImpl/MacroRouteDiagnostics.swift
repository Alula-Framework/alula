import AlulaDiagnostics
import AlulaMacroSupport
import AlulaRouteScan
import SwiftSyntax
import SwiftSyntaxMacros

/// Routes `RouteScanning`'s diagnostics back into the macro expansion that
/// asked for the scan, so they render inline at the attribute exactly as
/// they did when the scanner held the context itself.
struct MacroRouteDiagnostics<Context: MacroExpansionContext>: RouteDiagnostics {
    let context: Context

    func diagnose(_ code: DiagnosticCode, _ message: String, at node: some SyntaxProtocol) {
        context.diagnose(code, message, at: node)
    }
}
