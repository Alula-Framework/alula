import AlulaWeb

final class AccountDirectory: Sendable {}
final class OneTimeTokens: Sendable {}

// Written by `alula generate auth`; step 1 is to list it.
struct AccountsModule: AlulaModule {
    let directory: AccountDirectory
    let tokens: OneTimeTokens
}

@Service
struct AccountFlows {
    @Inject var directory: AccountDirectory
    @Inject var tokens: OneTimeTokens
}

struct AppModule: AlulaModule {
    let graph: AlulaGraph
    init(graph: AlulaGraph) { self.graph = graph }
}

@main struct Main {
    static func main() async {
        await Alula.run(configuration: .load(), modules: [AppModule.self])
    }
}
