/// The identity a `Socket` carries, as Channels needs to see it.
///
/// Channels' actual requirement is only "the join gate can read who this
/// is", so Channels owns the *seam*: a minimal protocol with exactly the two
/// members a join gate uses (`subject`, `hasRole(_:)`), and no dependency on
/// any particular identity implementation.
///
/// `AlulaSecurityCore.Principal` conforms to it — the demo wires exactly
/// that, resolving the principal in its socket route's authenticate closure
/// (`channels.socketRoute("/socket") { context in ... }`) — and so can an
/// application's own identity type. Same "seam, not engine" posture the rest
/// of the package takes with transports and adapters.
public protocol ChannelPrincipal: Sendable {
    /// The stable identity — a user ID, a service name.
    var subject: String { get }

    /// Whether this identity holds `role`. Defaults to false.
    func hasRole(_ role: String) -> Bool
}

extension ChannelPrincipal {
    /// False: roles are optional richness, and a bare subject-only principal
    /// is valid.
    public func hasRole(_ role: String) -> Bool { false }
}

/// The simplest useful principal — enough for tests, examples, and apps
/// whose upgrade-time authentication produces (subject, roles) directly.
public struct BasicPrincipal: ChannelPrincipal, Equatable {
    /// The stable identity.
    public let subject: String
    /// The roles ``hasRole(_:)`` checks against, exactly (case-sensitive).
    public let roles: Set<String>

    /// A principal with `subject` and `roles`.
    public init(subject: String, roles: Set<String> = []) {
        self.subject = subject
        self.roles = roles
    }

    /// Whether `roles` contains `role`.
    public func hasRole(_ role: String) -> Bool {
        roles.contains(role)
    }
}
