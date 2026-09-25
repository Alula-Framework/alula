import AlulaCore

struct BillingModule: AlulaModule {
    var commands: [CommandRegistration] {
        [CommandRegistration("seed", abstract: "Seed billing plans") { _ in }]
    }
}

struct CatalogModule: AlulaModule {
    var commands: [CommandRegistration] {
        [CommandRegistration("seed", abstract: "Seed the catalog") { _ in }]
    }
}

// Not in `modules:`, so its "seed" is not a conflict.
struct ArchiveModule: AlulaModule {
    var commands: [CommandRegistration] {
        [CommandRegistration("seed", abstract: "Seed the archive") { _ in }]
    }
}

@main struct Main {
    static func main() async {
        await Alula.run(
            configuration: .load(),
            modules: [BillingModule.self, CatalogModule.self])
    }
}
