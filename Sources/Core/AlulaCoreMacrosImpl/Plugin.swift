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
