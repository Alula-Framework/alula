import AlulaWeb

struct ClockModule: AlulaModule {
    let wallClock: Clock
    let monotonicClock: Clock
}

struct AppModule: AlulaModule {
    let graph: AlulaGraph
    init(graph: AlulaGraph) { self.graph = graph }
}

@Service
struct Reminders {
    @Inject(from: ClockModule.self) var clock: Clock
}

@main struct Main {
    static func main() async {
        await Alula.run(configuration: .load(), modules: [ClockModule.self, AppModule.self])
    }
}
