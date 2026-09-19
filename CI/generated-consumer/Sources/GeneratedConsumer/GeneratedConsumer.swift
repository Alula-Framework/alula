import FlightCore

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

@main
struct GeneratedConsumer {
    static func main() throws {
        // Building is the test. Constructing the graph proves the emitted
        // initializer is callable as written, not merely parseable.
        let graph = try FlightGraph(configuration: Configuration(values: ["app.name": "ci"]))
        print(graph.greeter.greet())
    }
}
