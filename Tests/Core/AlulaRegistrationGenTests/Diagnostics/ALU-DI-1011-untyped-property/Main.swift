import AlulaWeb

final class SchedulerStatus: Sendable {}

struct SchedulerModule: AlulaModule {
    let status = SchedulerStatus()
}

@main struct Main {
    static func main() async {
        await Alula.run(configuration: .load(), modules: [SchedulerModule.self])
    }
}
