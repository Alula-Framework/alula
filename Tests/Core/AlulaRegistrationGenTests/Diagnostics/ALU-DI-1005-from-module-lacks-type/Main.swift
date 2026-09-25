import AlulaWeb

struct ClockModule: AlulaModule {
    let clock: Clock
}

struct MailModule: AlulaModule {
    let mailer: Mailer
}

struct AppModule: AlulaModule {
    let graph: AlulaGraph
    init(graph: AlulaGraph) { self.graph = graph }
}

@Service
struct Reminders {
    @Inject(from: MailModule.self) var clock: Clock
}

@main struct Main {
    static func main() async {
        await Alula.run(
            configuration: .load(), modules: [ClockModule.self, MailModule.self, AppModule.self])
    }
}
