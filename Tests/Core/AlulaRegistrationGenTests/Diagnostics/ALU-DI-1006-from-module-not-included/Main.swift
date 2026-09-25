import AlulaWeb

struct ClockModule: AlulaModule {
    let clock: Clock
}

struct TestClockModule: AlulaModule {
    let clock: Clock
}

struct AppModule: AlulaModule {
    let graph: AlulaGraph
    init(graph: AlulaGraph) { self.graph = graph }
}

@Service
struct Reminders {
    @Inject(from: TestClockModule.self) var clock: Clock
}

@main struct Main {
    static func main() async {
        await Alula.run(configuration: .load(), modules: [ClockModule.self, AppModule.self])
    }
}
