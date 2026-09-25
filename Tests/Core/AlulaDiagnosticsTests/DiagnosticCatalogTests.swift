import Foundation
import Testing

@testable import AlulaDiagnostics

// The pages in Diagnostics/ are the one source of truth for every code's
// explanation: the docs link points at them, and `alula explain` prints the
// copy compiled into this module. These tests keep the three from drifting.

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
private let pagesDirectory = repositoryRoot.appendingPathComponent("Diagnostics")
private let catalogFile = repositoryRoot.appendingPathComponent(
    "Sources/Core/AlulaDiagnostics/Catalog.generated.swift")

private func pagesOnDisk() throws -> [String: String] {
    let names = try FileManager.default.contentsOfDirectory(atPath: pagesDirectory.path)
        .filter { $0.hasSuffix(".md") && $0 != "README.md" }
    var pages: [String: String] = [:]
    for name in names {
        pages[String(name.dropLast(3))] = try String(
            contentsOf: pagesDirectory.appendingPathComponent(name), encoding: .utf8)
    }
    return pages
}

private func catalogSource(_ pages: [String: String]) -> String {
    var out = """
        // Generated from Diagnostics/*.md — do not edit. Regenerate with:
        //   ALULA_REGENERATE_DIAGNOSTICS=1 swift test --filter DiagnosticCatalogTests
        enum DiagnosticCatalog {
            static let pages: [String: String] = [

        """
    for id in pages.keys.sorted() {
        out += "        \"\(id)\": ##\"\"\"\n"
        for line in pages[id]!.split(separator: "\n", omittingEmptySubsequences: false) {
            out += line.isEmpty ? "\n" : "            \(line)\n"
        }
        out += "            \"\"\"##,\n"
    }
    out += "    ]\n}\n"
    return out
}

private let indexFile = pagesDirectory.appendingPathComponent("README.md")

/// The directory's index, which GitHub shows above the file list: every code
/// and its title, by family, linked to its page.
private func indexSource() -> String {
    let families: [(prefix: String, name: String)] = [
        ("ALU-DI", "Dependency injection and graph construction"),
        ("ALU-WEB", "Controllers, routes, middleware, request binding"),
        ("ALU-OAPI", "OpenAPI generation"),
        ("ALU-CONFIG", "Configuration"),
        ("ALU-SEC", "Security and authentication composition"),
        ("ALU-CMD", "Commands"),
        ("ALU-LIFE", "Lifecycle and module composition"),
        ("ALU-SCHED", "Scheduled jobs"),
    ]
    var out = """
        # Alula diagnostic codes

        <!-- Generated from the pages in this directory — do not edit. Regenerate with:
             ALULA_REGENERATE_DIAGNOSTICS=1 swift test --filter DiagnosticCatalogTests -->

        Every error and warning Alula reports carries one of these codes. Each page
        says what the code means, why Alula rejects it, and how to fix it;
        `alula explain <code>` prints the same page offline. Two packages keep their
        own: Hangar's query codes, `HGR-QUERY-4xxx`, in
        [Hangar's repository](https://github.com/Alula-Framework/hangar/tree/main/Diagnostics),
        and alula-data's cache and migration codes, `ALD-…`, in
        [alula-data's](https://github.com/Alula-Framework/alula-data/tree/main/Diagnostics).

        """
    for family in families {
        let codes = DiagnosticCode.all.filter { $0.id.hasPrefix(family.prefix + "-") }
            .sorted { $0.id < $1.id }
        guard !codes.isEmpty else { continue }
        out += "\n## \(family.name)\n\n| Code | Severity | |\n|---|---|---|\n"
        for code in codes {
            out += "| [\(code.id)](\(code.id).md) | \(code.severity.rawValue) | \(code.title) |\n"
        }
    }
    return out
}

@Suite("Diagnostic catalog")
struct DiagnosticCatalogTests {
    @Test("the compiled catalog is the pages in Diagnostics/, exactly")
    func catalogIsCurrent() throws {
        let expected = catalogSource(try pagesOnDisk())
        if ProcessInfo.processInfo.environment["ALULA_REGENERATE_DIAGNOSTICS"] == "1" {
            try expected.write(to: catalogFile, atomically: true, encoding: .utf8)
        }
        let actual = try String(contentsOf: catalogFile, encoding: .utf8)
        #expect(actual == expected, "Catalog.generated.swift is stale: rerun with ALULA_REGENERATE_DIAGNOSTICS=1")
    }

    @Test("the directory index lists every code, exactly")
    func indexIsCurrent() throws {
        let expected = indexSource()
        if ProcessInfo.processInfo.environment["ALULA_REGENERATE_DIAGNOSTICS"] == "1" {
            try expected.write(to: indexFile, atomically: true, encoding: .utf8)
        }
        let actual = try String(contentsOf: indexFile, encoding: .utf8)
        #expect(actual == expected, "Diagnostics/README.md is stale: rerun with ALULA_REGENERATE_DIAGNOSTICS=1")
        for code in DiagnosticCode.all {
            #expect(actual.contains("[\(code.id)](\(code.id).md)"), "\(code.id) is missing from the index")
        }
    }

    @Test("every code has a page whose title and severity match, and every page a code")
    func codesAndPagesAgree() throws {
        let pages = try pagesOnDisk()
        #expect(Set(pages.keys) == Set(DiagnosticCode.all.map(\.id)))
        for code in DiagnosticCode.all {
            guard let page = pages[code.id] else { continue }
            let lines = page.split(separator: "\n").map(String.init)
            #expect(lines.first == "# \(code.id): \(code.title)", "\(code.id)'s page title")
            #expect(lines.contains("**Severity:** \(code.severity.rawValue)"), "\(code.id)'s severity")
            #expect(page.contains("## Meaning"), "\(code.id) explains its meaning")
            #expect(page.contains("## Fixes"), "\(code.id) says what to do")
        }
    }

    @Test("codes are unique, well-formed, and never share an id")
    func codesAreWellFormed() {
        let ids = DiagnosticCode.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for id in ids {
            #expect(id.wholeMatch(of: /(ALU-(DI|WEB|OAPI|CONFIG|SEC|CMD|LIFE|SCHED)|HGR-QUERY)-\d{4}/) != nil, "\(id)")
            let family = String(id.split(separator: "-").dropLast().joined(separator: "-"))
            let digit: [String: Character] = [
                "ALU-DI": "1", "ALU-WEB": "2", "ALU-OAPI": "3", "HGR-QUERY": "4", "ALU-CONFIG": "5",
                "ALU-SEC": "6", "ALU-CMD": "7", "ALU-LIFE": "8", "ALU-SCHED": "9",
            ]
            #expect(id.split(separator: "-").last?.first == digit[family], "\(id) is numbered outside its family")
        }
        #expect(DiagnosticCode.named("alu-di-1001") == .missingProvider)
    }
}

@Suite("Diagnostic rendering")
struct DiagnosticRenderingTests {
    @Test("compiler format: a located header, an indented body, docs, then located notes")
    func rendering() {
        let diagnostic = Diagnostic(
            .missingProvider, "no module provides `Mailer`",
            at: DiagnosticLocation(file: "Sources/App/Reset.swift", line: 12, column: 17),
            context: ["dependency path:", "  PasswordReset → Mailer"],
            help: ["add the module that holds a `Mailer` to `modules:`,\nor write the property's type."],
            notes: [.init("`MailModule.mailer` has no written type", at: DiagnosticLocation(file: "Sources/App/Mail.swift", line: 4, column: 9))])
        #expect(
            diagnostic.rendered == """
                Sources/App/Reset.swift:12:17: error: [ALU-DI-1001] no module provides `Mailer`
                    dependency path:
                      PasswordReset → Mailer
                    help: add the module that holds a `Mailer` to `modules:`,
                          or write the property's type.
                    docs: \(DiagnosticCode.documentationBase)ALU-DI-1001.md
                Sources/App/Mail.swift:4:9: note: `MailModule.mailer` has no written type
                """)
    }

    @Test("a code's severity is the default; a diagnostic may override it")
    func severity() {
        #expect(Diagnostic(.unscannedInjection, "x", at: nil).severity == .warning)
        #expect(Diagnostic(.unscannedInjection, severity: .error, "x", at: nil).rendered.hasPrefix("error: [ALU-DI-1009]"))
    }
}
