import AlulaCore
import AlulaWeb
import AlulaWebTesting
import Foundation
import HTTPTypes
import Testing

enum AppRole: String, RouteRole {
    case admin, billing, support
}

private struct TestPrincipal: RequestPrincipal {
    let subject: String
    let roles: Set<String>
    func hasRole(_ role: String) -> Bool { roles.contains(role) }
}

/// Writes an identity onto the request, standing in for real authentication.
private struct FakeAuthentication: Middleware {
    func handle(
        _ context: RequestContext, next: Next
    ) async throws -> Response {
        var context = context
        // `?as=admin,billing` names the roles; absent means anonymous.
        if let raw = context.request.queryParam("as") {
            context.identity = .authenticated(
                TestPrincipal(
                    subject: "u1", roles: Set(raw.split(separator: ",").map(String.init))))
        } else if context.request.queryParam("bad") != nil {
            context.identity = .invalidCredential
        }
        return try await next(context)
    }
}

@Controller("/admin", roles: [AppRole.admin])
struct RoleAdminController {
    // Inherits the controller's requirement.
    @GetRoute("/")
    func index(_ context: RequestContext) async throws -> String { "admin index" }

    // Narrows further: admin AND billing.
    @GetRoute("/invoices", roles: [AppRole.billing])
    func invoices(_ context: RequestContext) async throws -> String { "invoices" }

    // Any-of within one declaration.
    @GetRoute("/tickets", roles: [AppRole.billing, AppRole.support])
    func tickets(_ context: RequestContext) async throws -> String { "tickets" }
}

@Suite("Route roles")
struct RouteRoleTests {

    private func client() throws -> TestClient {
        try TestClient(
            routes: RoleAdminController.alulaRoutes { _ in RoleAdminController() },
            middleware: MiddlewareRegistration.lane(.default, [FakeAuthentication()]))
    }

    @Test("a controller's roles close off every route below it")
    func controllerLevelApplies() async throws {
        let anonymous = try await client().get("/admin/")
        #expect(anonymous.status == .unauthorized)

        let wrongRole = try await client().get("/admin/?as=support")
        #expect(wrongRole.status == .forbidden)

        let admin = try await client().get("/admin/?as=admin")
        #expect(admin.status == .ok)
    }

    @Test("a route's roles narrow rather than replace")
    func routeLevelNarrows() async throws {
        // Admin alone is no longer enough: the route adds billing.
        let adminOnly = try await client().get("/admin/invoices?as=admin")
        #expect(adminOnly.status == .forbidden)

        // Billing alone fails the controller's requirement — which is the
        // direction that would be a hole if route roles replaced.
        let billingOnly = try await client().get("/admin/invoices?as=billing")
        #expect(billingOnly.status == .forbidden)

        let both = try await client().get("/admin/invoices?as=admin,billing")
        #expect(both.status == .ok)
    }

    @Test("several roles in one declaration are any-of")
    func anyOfWithinADeclaration() async throws {
        let viaBilling = try await client().get("/admin/tickets?as=admin,billing")
        let viaSupport = try await client().get("/admin/tickets?as=admin,support")
        let neither = try await client().get("/admin/tickets?as=admin")
        #expect(viaBilling.status == .ok)
        #expect(viaSupport.status == .ok)
        #expect(neither.status == .forbidden)
    }

    @Test("no credential and a rejected credential are both 401, and distinguishable")
    func identityStates() async throws {
        let anonymous = try await client().get("/admin/")
        let rejected = try await client().get("/admin/?bad=1")
        #expect(anonymous.status == .unauthorized)
        #expect(rejected.status == .unauthorized)
        #expect(anonymous.bodyText != rejected.bodyText)
    }

    @Test("the 403 names what would have been enough")
    func forbiddenNamesTheRoles() async throws {
        let response = try await client().get("/admin/tickets?as=admin")
        #expect(response.status == .forbidden)
        #expect(response.bodyText.contains("billing"))
        #expect(response.bodyText.contains("support"))
    }
}
