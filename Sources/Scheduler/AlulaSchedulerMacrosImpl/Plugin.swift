import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

@main
struct AlulaSchedulerMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        SchedulerMacro.self,
        ScheduledMacro.self,
    ]
}
