/// A role a route can require.
///
/// Your own type, not a string: a typo in `[AppRole.admin]` is a compile
/// error, and a typo in `["admin"]` is a 403 nobody notices until someone
/// reports that they cannot reach a page they should.
///
/// ```swift
/// enum AppRole: String, RouteRole {
///     case admin, billing, support
/// }
///
/// @Controller("/admin", roles: [AppRole.admin])
/// struct AdminController {
///     @GetRoute("/invoices", roles: [AppRole.billing])   // admin AND billing
///     func invoices(_ context: RequestContext) async throws -> [Invoice]
/// }
/// ```
///
/// A `String`-backed `RawRepresentable` needs no more than the conformance;
/// anything else provides ``roleName`` itself. The name is what reaches
/// ``RequestPrincipal/hasRole(_:)``, so it has to match what the identity
/// provider issues — the type buys you spelling, not agreement with the IdP.
public protocol RouteRole: Sendable {
    /// The role as the principal knows it.
    var roleName: String { get }
}

extension RouteRole where Self: RawRepresentable, Self.RawValue == String {
    public var roleName: String { rawValue }
}

/// Not user API — what a generated route handler calls.
///
/// One check, run before the controller is constructed, so an unauthorised
/// request never reaches application code. The three-state identity is the
/// reason this lives here rather than in a middleware someone writes: "no
/// credential" and "a credential that failed validation" are different facts
/// and earn different answers, and hand-rolled guards routinely collapse them
/// into one 401 — or worse, into a 403 that tells an anonymous caller the
/// route exists.
///
/// - `.anonymous` → 401, no challenge detail to leak.
/// - `.invalidCredential` → 401, distinguishable for an RFC 6750 challenge.
/// - authenticated, role missing → 403.
public func requireRoles<Role: RouteRole>(
    _ roles: [Role], in context: RequestContext
) throws {
    // An empty list is a no-op rather than a lockout: it is what an
    // unprotected route resolves to, and reading it as "no role suffices"
    // would deny everything.
    guard !roles.isEmpty else { return }

    switch context.identity {
    case .anonymous:
        throw HTTPError(.unauthorized, "authentication required")
    case .invalidCredential:
        throw HTTPError(.unauthorized, "invalid credentials")
    case .authenticated(let principal):
        // Any-of within one declaration. Several declarations — a
        // controller's and a route's — are separate calls, so they compose as
        // "and", which is the direction that cannot accidentally widen
        // access.
        guard roles.contains(where: { principal.hasRole($0.roleName) }) else {
            let names = roles.map(\.roleName).sorted().joined(separator: ", ")
            throw HTTPError(.forbidden, "requires one of: \(names)")
        }
    }
}
