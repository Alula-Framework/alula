import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

@main
struct AlulaCoreMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ComponentMacro.self,  // unavailable; kept one release, see its comment
        ServiceMacro.self,
        RepositoryMacro.self,
        InjectMacro.self,
        ConfigValueMacro.self,
        SettingsMacro.self,
        SecretMacro.self,
    ]
}
