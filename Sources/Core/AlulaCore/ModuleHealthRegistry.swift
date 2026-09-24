import Synchronization

/// Per-module health, tracked outside the assembly.
///
/// This used to live on `Container` — the one genuinely-runtime thing it
/// carried, mutated during the service phase while everything else it held was
/// frozen. With the container gone (COMPOSITION-MIGRATION.md §9), health needs
/// an owner of its own: bootstrap creates one, seeds it with the module names,
/// updates it as services run, and hands it to whatever reports it (Actuator).
///
/// `reportHealth(_:forModule:)` is the documented public seam for "up but lost
/// its database" — a module reports its own state; nothing polls, so the
/// cadence stays off the request path.
public final class ModuleHealthRegistry: Sendable {
    private struct State {
        var order: [String] = []
        var map: [String: ModuleHealth] = [:]
        var draining = false
    }
    private let state = Mutex(State())

    public init() {}

    /// Seeds every module as `.notStarted`, in order — so a module that never
    /// runs a service still counts toward readiness.
    public func beginTracking(moduleNames: [String]) {
        state.withLock { state in
            state.order = moduleNames
            state.map = Dictionary(
                uniqueKeysWithValues: moduleNames.map { ($0, ModuleHealth.notStarted) })
        }
    }

    /// Records a module's health from outside its own lifecycle. Safe from any
    /// task, at any time.
    public func reportHealth(_ health: ModuleHealth, forModule moduleName: String) {
        set(moduleName, health)
    }

    func set(_ moduleName: String, _ health: ModuleHealth) {
        state.withLock { state in
            if state.map[moduleName] == nil { state.order.append(moduleName) }
            state.map[moduleName] = health
        }
    }

    /// `true` once graceful shutdown has begun. Readiness answers no from here
    /// on, while the transport is still serving, so an orchestrator stops
    /// routing to this process before it stops listening.
    public var isDraining: Bool {
        state.withLock { $0.draining }
    }

    /// Marks the process as shutting down. Idempotent; there is no way back.
    public func beginDraining() {
        state.withLock { $0.draining = true }
    }

    public func statuses() -> [ModuleStatus] {
        state.withLock { state in
            state.order.compactMap { name in
                state.map[name].map { ModuleStatus(moduleName: name, health: $0) }
            }
        }
    }
}
