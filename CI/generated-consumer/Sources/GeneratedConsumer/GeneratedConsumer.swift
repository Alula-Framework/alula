import AlulaCore

/// A configuration-reading component: the shape whose generated graph
/// initializer throws, and therefore the one whose emitted `try` spelling has
/// to be right. A fixture without a @ConfigValue would compile happily and
/// prove nothing — the generator only emits the throwing form when a node has
/// configuration to read.
@Component
struct Settings {
    @ConfigValue("app.name") var appName: String
}

/// A second component that depends on the first, so the emitted graph has an
/// ordering edge as well as a throwing node.
@Service
struct Greeter: Sendable {
    @Inject var settings: Settings

    func greet() -> String { "hello from \(settings.appName)" }
}

/// A module holding the collection-typed requirements as stored properties,
/// the way applications write them. The generator reads a module's stored
/// properties as what it provides, so these must pass through it cleanly.
struct HookedModule: AlulaModule {
    let lifecycleHooks: [LifecycleHook] = [.onStartup("say hello") { _ in }]
    let commands: [CommandRegistration] = [
        CommandRegistration("hello", abstract: "Say hello") { _ in }
    ]
}

@main
struct GeneratedConsumer {
    static func main() throws {
        // Building is the test. Constructing the graph proves the emitted
        // initializer is callable as written, not merely parseable.
        let graph = try AlulaGraph(configuration: Configuration(values: ["app.name": "ci"]))
        print(graph.greeter.greet())
    }
}
