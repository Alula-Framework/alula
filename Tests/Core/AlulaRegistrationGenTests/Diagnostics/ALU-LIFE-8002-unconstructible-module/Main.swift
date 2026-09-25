import AlulaWeb

struct ReportingModule: AlulaModule {
    init(warehouse: Warehouse, clock: Clock) {}
}

@main struct Main {
    static func main() async {
        await Alula.run(configuration: .load(), modules: [ReportingModule.self])
    }
}
