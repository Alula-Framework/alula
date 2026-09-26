import AlulaDiagnostics
import Foundation
import Testing

// Diagnostic quality, tested as an API.
//
// Each directory under Diagnostics/ is one invalid program and the exact text
// the build tool must answer it with — code, summary, location, context,
// help, docs link and notes. Asserting that a program merely *fails* would
// let a diagnostic regress into a generic Swift error unnoticed; these fail
// on any change to what the developer reads.
//
// A case directory: `*.swift` at the top level is the application target, and
// `*.yaml` beside it the package's configuration;
// each subdirectory is a dependency module of that name; `expected.txt` is
// the output, with the temporary workspace path removed. Record new output
// for review with `ALULA_UPDATE_GOLDEN=1`.

private let casesDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("Diagnostics")

private func caseNames() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: casesDirectory.path)) ?? [])
        .filter { !$0.hasPrefix(".") }.sorted()
}

private func swiftFiles(in directory: URL) throws -> [String: String] {
    var files: [String: String] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path)
    where name.hasSuffix(".swift") {
        files[name] = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }
    return files
}

extension GeneratorTests {
    @Test("every framework-owned diagnostic reads exactly as its golden file says", arguments: caseNames())
    func golden(_ name: String) throws {
        let directory = casesDirectory.appendingPathComponent(name)
        var dependencies: [String: [String: String]] = [:]
        for entry in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            var isDirectory: ObjCBool = false
            let path = directory.appendingPathComponent(entry)
            if FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory), isDirectory.boolValue {
                dependencies[entry] = try swiftFiles(in: path)
            }
        }
        // YAML beside the sources is the package's configuration.
        var configFiles: [String: String] = [:]
        for entry in try FileManager.default.contentsOfDirectory(atPath: directory.path) where entry.hasSuffix(".yaml") {
            configFiles[entry] = try String(contentsOf: directory.appendingPathComponent(entry), encoding: .utf8)
        }
        let result = try generate(
            try swiftFiles(in: directory), configFiles: configFiles, dependencyModules: dependencies)
        // `/tmp/…/alulagen-<uuid>/Main.swift:12:17` → `Main.swift:12:17`.
        let actual = result.diagnostics.replacing(/[^\s:]*alulagen-[0-9A-F-]+\//, with: "")
        let expectedURL = directory.appendingPathComponent("expected.txt")
        if ProcessInfo.processInfo.environment["ALULA_UPDATE_GOLDEN"] == "1" {
            try actual.write(to: expectedURL, atomically: true, encoding: .utf8)
        }
        let expected = try String(contentsOf: expectedURL, encoding: .utf8)
        #expect(actual == expected, "\(name): rerun with ALULA_UPDATE_GOLDEN=1 and review the diff")
        // The case is named for the code it proves, and the build agrees.
        let code = name.split(separator: "-").prefix(3).joined(separator: "-")
        #expect(actual.contains("[\(code)]"), "\(name) does not produce \(code)")
        let severity = DiagnosticCode.named(code)?.severity
        #expect((result.exitCode != 0) == (severity == .error), "\(name): exit status matches severity")
    }

    /// Framework-owned diagnostic coverage: the share of codes some test
    /// proves the build actually produces. A generator code is proven by a
    /// golden case here; a macro code by a macro test asserting it —
    /// `DiagnosticSpec.coded(.code, …)`, or the scheduler suite's
    /// `expectDiagnostic(…, .code, …)`. The target is all of them; a code
    /// without a test is a promise nothing checks.
    @Test("every diagnostic code has a test that produces it")
    func coverage() throws {
        let root = casesDirectory.deletingLastPathComponent()  // Tests/Core/AlulaRegistrationGenTests
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Static member name → id, read from the codes' declarations.
        let declarations = try String(
            contentsOf: root.appendingPathComponent("Sources/Core/AlulaDiagnostics/DiagnosticCode.swift"),
            encoding: .utf8)
        var ids: [String: String] = [:]
        for match in declarations.matches(of: /static let (\w+) = DiagnosticCode\(\s*"([A-Z0-9-]+)"/) {
            ids[String(match.1)] = String(match.2)
        }
        var proven = Set(caseNames().map { $0.split(separator: "-").prefix(3).joined(separator: "-") })
        for directory in ["Tests/Core/AlulaCoreMacroTests", "Tests/Web/AlulaWebMacroTests", "Tests/Scheduler/AlulaSchedulerMacroTests"] {
            let url = root.appendingPathComponent(directory)
            for file in try FileManager.default.contentsOfDirectory(atPath: url.path) where file.hasSuffix(".swift") {
                let source = try String(contentsOf: url.appendingPathComponent(file), encoding: .utf8)
                for match in source.matches(of: /(?:coded\(|""",\s*)\.(\w+),/) {
                    if let id = ids[String(match.1)] { proven.insert(id) }
                }
            }
        }
        // Runtime codes — reported by `Alula.run`, not the build — are proven
        // by a test asserting the bracketed code in the report, in whichever
        // module's tests reach the failure.
        let tests = root.appendingPathComponent("Tests")
        if let files = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil) {
            for case let url as URL in files where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                for match in source.matches(of: /#expect\(.*\[((?:ALU|HGR)-[A-Z]+-\d{4})\]/) {
                    proven.insert(String(match.1))
                }
            }
        }
        let codes = DiagnosticCode.all.map(\.id)
        let covered = codes.filter(proven.contains)
        print("framework-owned diagnostic coverage: \(covered.count)/\(codes.count)")
        #expect(covered.count == codes.count, "no test produces \(codes.filter { !proven.contains($0) })")
    }
}
