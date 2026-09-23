import AlulaCore

// Presentation vocabulary over Core's introspection types. Core keeps
// `ModuleHealth`/`Stereotype` free of rendering concerns; the labels both
// renderings share live here so JSON and SSR can never disagree about what a
// state is called.

extension ModuleHealth {
    // `isFailed` is Alula Core's own — declaring it here too made every use
    // ambiguous once Core added it.

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var isNotStarted: Bool {
        if case .notStarted = self { return true }
        return false
    }

    /// Stable machine-readable label, shared by the JSON encoding and the
    /// SSR table: "notStarted" | "running" | "failed".
    public var actuatorLabel: String {
        switch self {
        case .notStarted: return "notStarted"
        case .running: return "running"
        case .failed: return "failed"
        }
    }

    /// The failure's description for `.failed`, nil otherwise.
    ///
    /// Served verbatim on the dashboard, which is why it is worth saying out
    /// loud what that means: connection failures routinely interpolate the
    /// URL they failed on, and a URL can carry credentials. Reachable only
    /// under ``ActuatorExposure/full``, and only by whoever
    /// ``ActuatorDashboardAccess`` admits — anyone, unless configured — so
    /// anywhere `full` is on, treat these strings as disclosed to that
    /// audience. Credential
    /// scrubbing is not attempted here: guessing at which substrings are
    /// secret in an arbitrary error is the kind of half-measure that reads as
    /// a guarantee.
    public var failureDescription: String? {
        if case .failed(let error) = self { return String(describing: error) }
        return nil
    }
}

extension Stereotype {
    /// "component" | "service" | "repository" | "controller" | "settings" |
    /// "middleware".
    public var actuatorLabel: String {
        switch self {
        case .component: return "component"
        case .service: return "service"
        case .repository: return "repository"
        case .controller: return "controller"
        case .settings: return "settings"
        case .middleware: return "middleware"
        }
    }

    /// Section heading for the SSR dashboard's layer grouping (Alula Core
    ///: the stereotype tag exists to feed exactly this grouping).
    var actuatorSectionTitle: String {
        switch self {
        case .component: return "Components"
        case .service: return "Services"
        case .repository: return "Repositories"
        case .controller: return "Controllers"
        case .settings: return "Settings"
        case .middleware: return "Middleware"
        }
    }

    /// Dashboard section order: entry points first, then what wraps every
    /// one of them, then business logic, data access, what the app is
    /// configured with, and finally generic components.
    ///
    /// `@Middleware` and `@Settings` were added to `Stereotype` without
    /// updating this list — a component with a stereotype missing here is not
    /// swept into `.component`, it is silently absent from the dashboard
    /// entirely, present only in `alulaComponentDescriptors()`. Caught by
    /// booting Aluladeck and looking for "Settings" on its own actuator
    /// page rather than by any test, which is exactly the class of gap this
    /// project's own `GAPS.md` describes: a suite can pass entirely above
    /// the layer that's broken.
    static var actuatorSectionOrder: [Stereotype] {
        [.controller, .middleware, .service, .repository, .settings, .component]
    }
}
