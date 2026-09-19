import FlightCore
import FlightWeb
import FlightWebTesting
import Foundation
import HTTPTypes
import Testing

@Controller("/app")
private struct RedirectTestController {
    /// Stands in for a route whose roles were not met.
    @GetRoute("/dashboard")
    func dashboard(_ context: RequestContext) async throws -> String {
        throw HTTPError(.unauthorized, "authentication required")
    }

    /// Same, but reached with a query worth preserving.
    @GetRoute("/search")
    func search(_ context: RequestContext) async throws -> String {
        throw HTTPError(.unauthorized, "authentication required")
    }

    @GetRoute("/teapot")
    func teapot(_ context: RequestContext) async throws -> String {
        throw HTTPError(.internalServerError, "boom")
    }
}

@Suite("Redirects")
struct RedirectTests {

    // MARK: The response

    @Test("redirect defaults to the 303 a form POST wants")
    func defaultsToSeeOther() {
        let response = Response.redirect(to: "/projects/7")
        #expect(response.status == .seeOther)
        #expect(response.headers[.location] == "/projects/7")
        #expect(response.bodyData?.isEmpty == true)
    }

    @Test("each kind is the code it names")
    func kindsMapToCodes() {
        let expected: [(Response.Redirect, Int)] = [
            (.seeOther, 303), (.temporary, 307), (.permanent, 308),
            (.found, 302), (.movedPermanently, 301),
        ]
        for (kind, code) in expected {
            #expect(Response.redirect(to: "/x", kind).status.code == code)
            // Every one of them is a redirect as far as dispatch is
            // concerned, which is what the error mapper's body rule keys on.
            #expect(kind.status.kind == .redirection)
        }
    }

    @Test("seeOther is the same response as redirect(to:)")
    func seeOtherStillWorks() {
        let old = Response.seeOther("/dashboard")
        let new = Response.redirect(to: "/dashboard")
        #expect(old.status == new.status)
        #expect(old.headers[.location] == new.headers[.location])
    }

    // MARK: returnTo

    @Test("returnTo keeps a query whole instead of ending the parameter early")
    func returnToEncodesDelimiters() async throws {
        let client = try TestClient(
            routes: RedirectTestController.flightRoutes { _ in RedirectTestController() },
            web: WebRuntime(errorMapper: Self.loginRedirect))
        let response = await client.get(
            "/app/search?q=a&b=c", headers: [.accept: "text/html"])

        let location = try #require(response.headers[.location])
        // The point of the encoding: written raw, the `&` would end `next`
        // and the caller would come back having lost half their query.
        #expect(location == "/login?next=/app/search%3Fq%3Da%26b%3Dc")
        #expect(location.hasPrefix("/login?next="))
    }

    @Test("returnTo omits the question mark when there is no query")
    func returnToWithoutQuery() async throws {
        let client = try TestClient(
            routes: RedirectTestController.flightRoutes { _ in RedirectTestController() },
            web: WebRuntime(errorMapper: Self.loginRedirect))
        let response = await client.get("/app/dashboard", headers: [.accept: "text/html"])
        #expect(response.headers[.location] == "/login?next=/app/dashboard")
    }

    // MARK: The mapper

    /// The example from ``ErrorMapper``'s documentation, run.
    static let loginRedirect = ErrorMapper { error, context in
        guard (error as? any HTTPErrorRepresentable)?.httpStatus == .unauthorized,
            context.request.headers[.accept]?.contains("text/html") == true
        else { return nil }
        return .redirect(to: "/login?next=\(context.returnTo)")
    }

    @Test("a mapper reading the request turns a 401 into a sign-in redirect")
    func mapperSeesTheRequest() async throws {
        let client = try TestClient(
            routes: RedirectTestController.flightRoutes { _ in RedirectTestController() },
            web: WebRuntime(errorMapper: Self.loginRedirect))
        let response = await client.get("/app/dashboard", headers: [.accept: "text/html"])
        #expect(response.status == .seeOther)
        #expect(response.headers[.location] == "/login?next=/app/dashboard")
    }

    @Test("the same route keeps its 401 for a caller that did not ask for HTML")
    func apiCallersKeepTheirStatus() async throws {
        let client = try TestClient(
            routes: RedirectTestController.flightRoutes { _ in RedirectTestController() },
            web: WebRuntime(errorMapper: Self.loginRedirect))
        let response = await client.get(
            "/app/dashboard", headers: [.accept: "application/json"])
        #expect(response.status == .unauthorized)
        #expect(response.headers[.location] == nil)
    }

    @Test("a redirect mapping carries no error document")
    func redirectsHaveNoBody() async throws {
        let client = try TestClient(
            routes: RedirectTestController.flightRoutes { _ in RedirectTestController() },
            web: WebRuntime(errorMapper: Self.loginRedirect))
        let response = await client.get("/app/dashboard", headers: [.accept: "text/html"])
        // Not a problem+json behind a Location nobody reads past.
        #expect(response.bodyData?.isEmpty == true)
        #expect(response.headers[.contentType] == nil)
    }

    @Test("an error the mapper declines still renders the ordinary way")
    func declinedErrorsAreUnaffected() async throws {
        let client = try TestClient(
            routes: RedirectTestController.flightRoutes { _ in RedirectTestController() },
            web: WebRuntime(errorMapper: Self.loginRedirect))
        let response = await client.get("/app/teapot", headers: [.accept: "text/html"])
        #expect(response.status == .internalServerError)
        #expect(response.headers[.location] == nil)
        #expect(response.bodyData?.isEmpty == false)
    }

    @Test("the error-only mapper still compiles and still answers")
    func errorOnlyFormStillWorks() async throws {
        // The form every existing application is written in. It must keep
        // resolving to the one-argument initialiser against the overload.
        let mapper = ErrorMapper { (error: any Error) -> ErrorMapper.Mapping? in
            guard (error as? any HTTPErrorRepresentable)?.httpStatus == .unauthorized
            else { return nil }
            return .init(.gone, "subscription required")
        }
        let client = try TestClient(
            routes: RedirectTestController.flightRoutes { _ in RedirectTestController() },
            web: WebRuntime(errorMapper: mapper))
        let response = await client.get("/app/dashboard")
        #expect(response.status == .gone)
        #expect(response.bodyText.contains("subscription required"))
    }

    @Test("a mapper's non-redirect headers still merge, as they did")
    func headersStillMerge() async throws {
        let mapper = ErrorMapper { (_: any Error) -> ErrorMapper.Mapping? in
            .init(.serviceUnavailable, "busy", headers: [.retryAfter: "1"])
        }
        let client = try TestClient(
            routes: RedirectTestController.flightRoutes { _ in RedirectTestController() },
            web: WebRuntime(errorMapper: mapper))
        let response = await client.get("/app/dashboard")
        #expect(response.status == .serviceUnavailable)
        #expect(response.headers[.retryAfter] == "1")
    }
}
