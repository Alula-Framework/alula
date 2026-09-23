import AlulaCore
import AlulaTelemetryBridges
import TelemetryCore

/// The module:
///
/// ```swift
/// await Alula.run(configuration: try .load(), modules: [
///     AlulaAPNSModule.self,
///     AppModule.self,
/// ], composedBy: alulaComposeModules)
/// ```
///
/// ```yaml
/// apns:
///   key-id: ABC123DEFG
///   team-id: DEF456GHIJ
///   private-key-path: /run/secrets/apns.p8     # or private-key, the PEM itself
///   topic: com.example.app
///   environment: sandbox                       # production is the default
/// ```
///
/// Built in `init`: the configuration is read and the `.p8` parsed there,
/// so a missing key or a malformed one fails composition, never the first
/// push. The module provides ``APNSClient``; inject it wherever a push is
/// sent.
///
/// No `service`: the shared HTTP client needs no lifecycle, and the
/// provider token is minted on first use. Not gated on `Web` — a worker
/// that sends pushes from a scheduled job should not pay for an HTTP server.
public struct AlulaAPNSModule: AlulaModule {

    /// Reporting comes with the stack: `AlulaTelemetryModule` reports this
    /// module's metrics once a backend is bootstrapped.
    public static var dependencies: [any AlulaModule.Type] { [AlulaTelemetryModule.self] }
    /// `apns.*`, read once at composition.
    public let settings: APNSConfiguration

    /// The client this module provides.
    public let client: APNSClient

    /// ``APNSMetrics/definitions``, for `AlulaTelemetryModule` to report.
    public let telemetryMetrics: [TelemetryMetric] = APNSMetrics.definitions

    public init(configuration: Configuration) throws {
        let settings = try APNSConfiguration(configuration: configuration)
        self.settings = settings
        self.client = APNSClient(configuration: settings)
    }

    public init() {
        preconditionFailure(
            "AlulaAPNSModule takes its configuration in init(configuration:), so it cannot be "
                + "instantiated from its type. Pass `composedBy: alulaComposeModules` to "
                + "Alula.run — `alula new` writes that argument — or construct the module "
                + "yourself and use the entry point taking module instances.")
    }
}
