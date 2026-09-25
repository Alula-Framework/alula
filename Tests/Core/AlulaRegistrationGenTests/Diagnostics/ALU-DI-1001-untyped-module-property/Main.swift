import AlulaWeb

final class LabState: Sendable {}

struct LabModule: AlulaModule {
    let labState = LabState()
}

struct AppModule: AlulaModule {
    let graph: AlulaGraph
    init(graph: AlulaGraph) { self.graph = graph }
}

@Service
struct ExperimentService {
    @Inject var state: LabState
}

@main struct Main {
    static func main() async {
        await Alula.run(configuration: .load(), modules: [LabModule.self, AppModule.self])
    }
}
