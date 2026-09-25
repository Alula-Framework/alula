import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

@main
struct AlulaWebMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ControllerMacro.self,
        RouteMacro.self,
        MiddlewareMacro.self,
    ]
}
