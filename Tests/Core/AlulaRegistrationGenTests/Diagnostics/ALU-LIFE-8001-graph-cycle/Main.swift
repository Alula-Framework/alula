import AlulaWeb

final class FaultPlan: Sendable {}

// Holds the plan, and takes the graph — whose services need the plan.
struct RelayModule: AlulaModule {
    let faults: FaultPlan
    init(configuration: Configuration, graph: AlulaGraph) { faults = FaultPlan() }
}

@Service
final class Escalations {
    @Inject var faults: FaultPlan
}

// Takes the graph too, and did nothing wrong.
struct RealtimeModule: AlulaModule {
    init(graph: AlulaGraph) {}
}

@main struct Main {
    static func main() async {
        await Alula.run(configuration: .load(), modules: [RealtimeModule.self, RelayModule.self])
    }
}
