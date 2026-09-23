// AlulaRegistrationPlugin
//
// Attached to an app (or module) target, this plugin plans one build command
// that runs alula-registration-gen over the target's own sources plus the
// sources of every recursive source-module dependency that sits atop
// AlulaCore, producing AlulaRegistration.generated.swift with the generated
// composition root (alulaComposeModules, AlulaGraph, alulaRoutes, ...).
//
// Why source scanning and not symbol graphs: symbol graphs are compiler
// outputs that do not exist when a build tool plugin's commands are planned,
// and the PackageManager symbol-graph service is only exposed to *command*
// plugins (SE-0332). SE-0325 gives build tool plugins the package graph —
// including dependency targets' source files — and the plugin sandbox allows
// reading them.
//
// Sandbox notes (spike question (b)): no network; writes restricted to this
// plugin's work directory (both the manifest and the generated file live
// there); reads of package/dependency sources are permitted.

import Foundation
import PackagePlugin

@main
struct AlulaRegistrationPlugin: BuildToolPlugin {

    // Shape shared with Sources/alula-registration-gen.
    struct Manifest: Codable {
        struct Module: Codable {
            let name: String
            let files: [String]
        }
        let targetModuleName: String
        let modules: [Module]
        let output: String
        // Where alula.yaml lives (the package owning the target), for the
        // Alula Config the compile-time @ConfigValue key check.
        let packageDirectory: String?
    }

    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let sourceModule = target.sourceModule else { return [] }

        // The target itself, plus every recursive source-module dependency
        // that (transitively) depends on AlulaCore. That predicate keeps
        // swift-log, swift-service-lifecycle, and friends out of the scan.
        var modulesInScope: [SourceModuleTarget] = [sourceModule]
        for dependency in target.recursiveTargetDependencies {
            guard let dependencyModule = dependency.sourceModule else { continue }
            guard dependencyModule.name != "AlulaCore" else { continue }
            let dependsOnAlulaCore = dependency.recursiveTargetDependencies
                .contains { $0.name == "AlulaCore" }
            if dependsOnAlulaCore {
                modulesInScope.append(dependencyModule)
            }
        }

        var inputFiles: [URL] = []
        var manifestModules: [Manifest.Module] = []
        for module in modulesInScope {
            let swiftFiles = module.sourceFiles(withSuffix: ".swift").map(\.url)
            guard !swiftFiles.isEmpty else { continue }
            inputFiles.append(contentsOf: swiftFiles)
            manifestModules.append(
                Manifest.Module(name: module.moduleName, files: swiftFiles.map(\.path))
            )
        }

        let workDirectory = context.pluginWorkDirectoryURL
        let outputURL = workDirectory.appendingPathComponent("AlulaRegistration.generated.swift")
        let manifestURL = workDirectory.appendingPathComponent("alula-manifest.json")

        // The base config file participates in the build: it is an input of
        // the generator's @ConfigValue key check, so editing it must re-plan
        // the codegen command.
        //
        // Every *.yaml at the package root is declared, not just alula.yaml,
        // because an application may name its own (`Configuration.load(prefix:)`)
        // and the generator reads that name out of the application's source —
        // which this plugin does not parse. Declaring a superset of inputs is a
        // build-graph over-approximation: it can only cause the command to
        // re-run when it needn't have. That is categorically different from
        // using a file's presence to decide *semantics*, which is the pattern
        // this framework rejects — which file is authoritative is still
        // decided by the scanned `prefix:`, never by what happens to be here.
        let packageDirectory = context.package.directoryURL
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: packageDirectory, includingPropertiesForKeys: nil)
        {
            for entry in entries where entry.pathExtension == "yaml" {
                inputFiles.append(entry)
            }
        }

        let manifest = Manifest(
            targetModuleName: sourceModule.moduleName,
            modules: manifestModules,
            output: outputURL.path,
            packageDirectory: packageDirectory.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL)

        return [
            .buildCommand(
                displayName: "Alula registration codegen for \(target.name)",
                executable: try context.tool(named: "alula-registration-gen").url,
                arguments: [manifestURL.path],
                inputFiles: inputFiles + [manifestURL],
                outputFiles: [outputURL]
            )
        ]
    }
}
