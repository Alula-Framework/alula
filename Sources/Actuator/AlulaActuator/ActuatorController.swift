import AlulaCore
import AlulaWeb
import Foundation

/// The dashboard. A plain struct, not `@Controller` — deliberately: it is
/// built and held by ``ActuatorModule`` (in its controller box), and its
/// routes are values the module declares.
///
/// Alula Core's registration plugin scans every recursive source-module
/// dependency that sits atop AlulaCore for `@Component`/`@Controller`
/// types — right for an app-owned library target (so an app never has to wire
/// it), wrong for a starter package with its own `AlulaModule`: a downstream
/// app's generated composition root would try to build this type as one of
/// its own graph nodes — bypassing `ActuatorModule`'s exposure gate entirely
/// (whole point) and colliding with what `ActuatorModule` already does. Every
/// other starter (`alula-web`, `alula-pubsub`, `alula-channels`,
/// `alula-data-postgres`) avoids this the same way: none put
/// `@Component`/`@Controller` on their own infrastructure, wiring it from that
/// package's own `AlulaModule` instead. This mirrors that.
///
/// Internal deliberately: `ActuatorModule` constructs it and serves it through
/// route values (`RouteRegistration`, the same seam `@GetRoute` sits beside);
/// nothing outside this package touches it directly.
struct ActuatorController {
    /// One encoder, configured once.
    ///
    /// Both responses want the same deterministic formatting, and the health
    /// probe is — as the comment in `respond(to:)` says — the one route an
    /// orchestrator polls every few seconds. Building a `JSONEncoder` per
    /// poll bought nothing; the settings never vary.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// Every component, as the *build* scanned them — passed in by the
    /// composition root rather than read from `container.allRegistrations()`.
    ///
    /// A better answer than the container's, and available before the process
    /// starts: what the build found is what the graph constructs. It does not
    /// carry anything registered through the imperative escape hatch, which is
    /// the deliberate trade — see COMPOSITION-MIGRATION.md §2.9.
    let components: [ComponentDescriptor]

    /// Module health is genuinely runtime state, so it still comes from the
    /// thing that tracks it.
    let health: @Sendable () -> [ModuleStatus]

    /// Whether graceful shutdown has begun — readiness answers no from then on.
    let isDraining: @Sendable () -> Bool

    /// Dependencies readiness asks about beyond module health.
    let readinessChecks: ReadinessChecks

    let environment: AlulaEnvironment
    let format: ActuatorFormat
    var buildInfo = ActuatorBuildInfo()

    /// Overall health, with nothing in it worth hiding.
    ///
    /// Deliberately minimal: an overall status and per-module counts, with no
    /// component list, no type names, and no failure text. This is the one
    /// actuator surface safe to publish unauthenticated in production, and it
    /// is only safe because of what it leaves out — a probe needs to know
    /// whether to act, not what the pod is made of.
    ///
    /// `200` when every module is running, `503` otherwise, so an
    /// orchestrator can read the status code alone. This is the strict
    /// reading, which is the readiness question; see ``liveness(_:)`` for the
    /// one an orchestrator should restart on.
    func health(_ context: RequestContext) async throws -> Response {
        try await respond(to: .readiness)
    }

    /// Is this process wedged — should the orchestrator restart it?
    ///
    /// A module that has not started yet does **not** count against liveness:
    /// a slow-starting pod answering `DOWN` here gets killed and restarted
    /// into the same slow start, forever. Only a module whose service threw
    /// counts, because that is the state a restart can actually clear.
    func liveness(_ context: RequestContext) async throws -> Response {
        try await respond(to: .liveness)
    }

    /// Can this process serve traffic yet?
    ///
    /// Strict: a module still starting, or failed, means no. Identical to
    /// ``health(_:)``, and named so a deployment does not have to know that.
    func readiness(_ context: RequestContext) async throws -> Response {
        try await respond(to: .readiness)
    }

    /// Which question a probe is asking. One endpoint answered both, and the
    /// two want opposite things from a module that has not started yet.
    private enum Probe {
        case liveness
        case readiness
    }

    private func respond(to probe: Probe) async throws -> Response {
        // `health()` rather than a full `ActuatorSnapshot`: the snapshot also
        // copies the entire component descriptor table, and this path used
        // every bit of it to compute three integers — on the one route an
        // orchestrator polls every few seconds.
        let modules = health()
        let failed = modules.filter(\.health.isFailed).count
        let notStarted = modules.filter(\.health.isNotStarted).count
        // Dependency checks and draining are readiness questions only: a
        // restart brings back neither a database nor a process that is on its
        // way out, so neither may fail liveness.
        let draining = probe == .readiness && isDraining()
        let checksFailed = probe == .readiness ? await readinessChecks.failedCount() : 0
        let up =
            switch probe {
            case .liveness: failed == 0
            case .readiness: failed == 0 && notStarted == 0 && checksFailed == 0 && !draining
            }

        struct Health: Encodable {
            let status: String
            let modules: Int
            let failed: Int
            let notStarted: Int
            let checksFailed: Int?
            let draining: Bool?
        }
        let body = try Self.encoder.encode(
            Health(
                status: up ? "UP" : "DOWN",
                modules: modules.count,
                failed: failed,
                notStarted: notStarted,
                checksFailed: probe == .readiness && !readinessChecks.isEmpty ? checksFailed : nil,
                draining: draining ? true : nil))
        return .data(
            body, contentType: .json, status: up ? .ok : .serviceUnavailable)
    }

    /// Which build is running, and since when; see ``ActuatorBuildInfo``.
    func info(_ context: RequestContext) async throws -> Response {
        .data(
            try Self.encoder.encode(buildInfo.document(environment: environment)),
            contentType: .json)
    }

    func dashboard(_ context: RequestContext) async throws -> Response {
        let snapshot = ActuatorSnapshot(
            environment: environment, modules: health(), components: components,
            checks: await readinessChecks.results().map {
                ActuatorSnapshot.CheckStatus(name: $0.name, result: $0.result)
            })
        switch format {
        case .ssr:
            return .html(renderActuatorHTML(snapshot))
        case .json:
            // Deterministic output: the JSON is a public contract for
            // hand-rolled front-ends, so key order should not wobble
            // between requests or releases. `Self.encoder` is configured for
            // exactly that.
            return .data(try Self.encoder.encode(snapshot), contentType: .json)
        }
    }
}
