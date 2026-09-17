import FlightActuator
import FlightCore
import FlightWeb
import ServiceLifecycle

// Shared test fixtures. All go through public Flight contracts only —
// Actuator is a consumer of the stack, and so are its tests.

/// The components one sample app would contribute — one of each stereotype
/// the dashboard needs to distinguish, plus a duplicate-type pair: two
/// registrations of one type are two rows, not one deduplicated row. They used
/// to be told apart by their qualifiers, which the descriptor no longer
/// carries (0.20.0); that they both still appear is the part that mattered.
///
/// This is the shape the generated `flightComponentDescriptors()` produces
/// and the composition root hands `ActuatorModule(components:)`. Written out
/// here because no plugin runs over these fixtures — the dashboard lists what
/// the *build* found, not what any container happened to hold.
enum SampleAppModule {
    static let components: [ComponentDescriptor] = [
        ComponentDescriptor(
            typeName: "FlightActuatorTests.SampleService",
            sourceModule: "SampleAppModule", stereotype: .service),
        ComponentDescriptor(
            typeName: "FlightActuatorTests.SampleRepository",
            sourceModule: "SampleAppModule", stereotype: .repository),
        ComponentDescriptor(
            typeName: "FlightActuatorTests.SampleDuplicated",
            sourceModule: "SampleAppModule", stereotype: .component),
        ComponentDescriptor(
            typeName: "FlightActuatorTests.SampleDuplicated",
            sourceModule: "SampleAppModule", stereotype: .component),
        ComponentDescriptor(
            typeName: "FlightActuatorTests.SampleMiddleware",
            sourceModule: "SampleAppModule", stereotype: .middleware),
        ComponentDescriptor(
            typeName: "FlightActuatorTests.SampleSettings",
            sourceModule: "SampleAppModule", stereotype: .settings),
        ComponentDescriptor(
            typeName: "FlightActuatorTests.SampleController",
            sourceModule: "SampleAppModule", stereotype: .controller),
    ]
}

struct SampleService: Sendable {}
struct SampleRepository: Sendable {}
struct SampleDuplicated: Sendable {}
struct SampleMiddleware: Sendable {}
struct SampleSettings: Sendable {}

/// A real `@Controller`, expanded by the macro, so the fixture's controller
/// descriptor stands for an actual controller type rather than a string.
@Controller("/sample")
struct SampleController {
    @GetRoute("/ping")
    func ping(_ context: RequestContext) -> String { "pong" }
}

/// The components for a module whose *type name* is an XSS probe — the SSR
/// escaping tests feed the renderer through these.
///
/// The probe used to ride the qualifier, which the descriptor no longer
/// carries. It moved to the type name rather than being deleted with the
/// field: every string on that table is still app-controlled input rendered
/// into HTML, so the escaping guarantee is exactly as load-bearing as it was.
enum HostileNameModule {
    static let hostileName = #"<script>alert("pwned")</script>"#

    static let components: [ComponentDescriptor] = [
        ComponentDescriptor(
            typeName: hostileName,
            sourceModule: "HostileNameModule",
            stereotype: .component)
    ]
}

/// A module whose service fails during the run phase — the only way module
/// health legitimately reaches `.failed` on a live assembly (Flight Core:
/// configure failures abort bootstrap entirely).
struct FailingServiceModule: FlightModule {
    struct Boom: Error, CustomStringConvertible {
        var description: String { "boom: the flux capacitor de-fluxed" }
    }

    struct FailingService: Service {
        func run() async throws {
            throw Boom()
        }
    }

    var service: (any Service)? { FailingService() }
}
