import AlulaWeb

struct PrimaryDataModule: AlulaModule {
    let pool: DataPool
}

struct AnalyticsDataModule: AlulaModule {
    let pool: DataPool
}

struct AppModule: AlulaModule {
    let graph: AlulaGraph
    init(graph: AlulaGraph) { self.graph = graph }
}

@Repository
struct OrderRepository {
    @Inject var pool: DataPool
}

@main struct Main {
    static func main() async {
        await Alula.run(
            configuration: .load(),
            modules: [PrimaryDataModule.self, AnalyticsDataModule.self, AppModule.self])
    }
}
