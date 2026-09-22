import FlightCore
import FlightWebTesting
import Foundation
import HTTPTypes
import Testing

@testable import FlightWeb

@Controller("/")
private struct SecurityHeadersController {
    @GetRoute("/page")
    func page(_ context: RequestContext) -> String { "page" }

    /// A route with its own lane and nothing from `.default` — the shape a
    /// middleware would miss.
    @GetRoute("/private", pipelines: ["private"])
    func privatePage(_ context: RequestContext) -> String { "private" }

    /// A route that means to be framed by its own origin, deciding so itself.
    @GetRoute("/embeddable")
    func embeddable(_ context: RequestContext) -> Response {
        Response.text("embed me").settingHeader(.xFrameOptions, "SAMEORIGIN")
    }

    @GetRoute("/fails")
    func fails(_ context: RequestContext) throws -> String {
        throw HTTPError(.badRequest, "no")
    }
}

@Suite("SecurityHeaders")
struct SecurityHeadersTests {

    private func client(_ headers: SecurityHeaders = .default) throws -> TestClient {
        try TestClient(
            routes: SecurityHeadersController.flightRoutes { _ in SecurityHeadersController() },
            middleware: MiddlewareRegistration.lane("private", []),
            web: WebRuntime(securityHeaders: headers))
    }

    @Test("header names are valid literals")
    func headerNamesAreValid() {
        #expect(HTTPField.Name("x-frame-options") != nil)
        #expect(HTTPField.Name("referrer-policy") != nil)
    }

    // MARK: Defaults

    @Test("the defaults are nosniff, DENY and a strict referrer policy, and nothing else")
    func defaults() async throws {
        let response = await try client().get("/page")
        #expect(response.header("X-Content-Type-Options") == "nosniff")
        #expect(response.header("X-Frame-Options") == "DENY")
        #expect(response.header("Referrer-Policy") == "strict-origin-when-cross-origin")
        #expect(response.header("Strict-Transport-Security") == nil)
        #expect(response.header("Content-Security-Policy") == nil)
    }

    @Test("configuration with no security-headers keys gives the defaults")
    func configurationDefaults() throws {
        #expect(try SecurityHeaders(configuration: Configuration()) == .default)
    }

    @Test("a hand-built WebRuntime adds nothing unasked")
    func runtimeDefaultIsNone() async throws {
        let response = await try client(.none).get("/page")
        #expect(response.header("X-Frame-Options") == nil)
        #expect(response.header("X-Content-Type-Options") == nil)
    }

    // MARK: Why this is not a middleware

    @Test("a route running only its own lane still gets every header")
    func routeWithOwnLaneIsCovered() async throws {
        // A middleware in `.default` would not run here at all.
        let response = await try client().get("/private")
        #expect(response.status == .ok)
        #expect(response.header("X-Frame-Options") == "DENY")
        #expect(response.header("X-Content-Type-Options") == "nosniff")
    }

    @Test("a 404 and a handler's error response are covered too")
    func errorsAndMissesAreCovered() async throws {
        let client = try client()
        let missing = await client.get("/nowhere")
        #expect(missing.status == .notFound)
        #expect(missing.header("X-Frame-Options") == "DENY")

        let failed = await client.get("/fails")
        #expect(failed.status == .badRequest)
        #expect(failed.header("X-Frame-Options") == "DENY")
    }

    @Test("a header the route set itself wins over the application default")
    func routeDecisionWins() async throws {
        let response = await try client().get("/embeddable")
        #expect(response.header("X-Frame-Options") == "SAMEORIGIN")
        #expect(response.headerValues("X-Frame-Options").count == 1)
        // The other defaults still fill in around it.
        #expect(response.header("X-Content-Type-Options") == "nosniff")
    }

    // MARK: Configuration

    @Test("each default-on header can be switched off, with off or false")
    func switchingOff() throws {
        let headers = try SecurityHeaders(
            configuration: Configuration(values: [
                SecurityHeadersConfigKey.contentTypeOptions: "off",
                SecurityHeadersConfigKey.frameOptions: "false",
                SecurityHeadersConfigKey.referrerPolicy: "OFF",
            ]))
        #expect(headers == .none)
    }

    @Test("frame-options sameorigin and another referrer policy are read")
    func alternatives() throws {
        let headers = try SecurityHeaders(
            configuration: Configuration(values: [
                SecurityHeadersConfigKey.frameOptions: "sameorigin",
                SecurityHeadersConfigKey.referrerPolicy: "no-referrer",
            ]))
        #expect(headers.frameOptions == .sameOrigin)
        #expect(headers.referrerPolicy == "no-referrer")
    }

    @Test("HSTS and CSP are sent only when configured, exactly as configured")
    func hstsAndCSP() async throws {
        let headers = try SecurityHeaders(
            configuration: Configuration(values: [
                SecurityHeadersConfigKey.hstsMaxAge: "31536000s",
                SecurityHeadersConfigKey.hstsIncludeSubdomains: "true",
                SecurityHeadersConfigKey.contentSecurityPolicy: "default-src 'self'",
            ]))
        let response = await try client(headers).get("/page")
        #expect(
            response.header("Strict-Transport-Security") == "max-age=31536000; includeSubDomains")
        #expect(response.header("Content-Security-Policy") == "default-src 'self'")
    }

    @Test("an unrecognized value fails composition, naming the key")
    func unrecognizedValues() {
        #expect(
            throws: SecurityHeadersConfigurationError.invalid(
                key: SecurityHeadersConfigKey.frameOptions, "allow-from https://x")
        ) {
            try SecurityHeaders(
                configuration: Configuration(values: [
                    SecurityHeadersConfigKey.frameOptions: "allow-from https://x"
                ]))
        }
        #expect(throws: SecurityHeadersConfigurationError.unknownReferrerPolicy("strict")) {
            try SecurityHeaders(
                configuration: Configuration(values: [
                    SecurityHeadersConfigKey.referrerPolicy: "strict"
                ]))
        }
    }

    @Test("an HSTS modifier with no max-age is refused rather than silently ignored")
    func hstsModifierAlone() {
        #expect(throws: SecurityHeadersConfigurationError.hstsModifierWithoutMaxAge) {
            try SecurityHeaders(
                configuration: Configuration(values: [
                    SecurityHeadersConfigKey.hstsIncludeSubdomains: "true"
                ]))
        }
    }

    @Test("preload is refused unless the preload list would accept it")
    func preloadRequirements() {
        #expect(throws: SecurityHeadersConfigurationError.preloadRequirementsNotMet) {
            try SecurityHeaders(
                strictTransportSecurity: .init(maxAge: .seconds(86_400), preload: true))
        }
        #expect(throws: SecurityHeadersConfigurationError.preloadRequirementsNotMet) {
            try SecurityHeaders(
                strictTransportSecurity: .init(maxAge: .seconds(31_536_000), preload: true))
        }
        #expect(throws: Never.self) {
            try SecurityHeaders(
                strictTransportSecurity: .init(
                    maxAge: .seconds(63_072_000), includeSubdomains: true, preload: true))
        }
    }

    @Test("FlightWebModule reads the policy from configuration")
    func moduleReadsConfiguration() async throws {
        let module = try FlightWebModule<InMemoryTransport>(
            configuration: Configuration(values: [
                SecurityHeadersConfigKey.frameOptions: "sameorigin"
            ]),
            routes: SecurityHeadersController.flightRoutes { _ in SecurityHeadersController() },
            middleware: MiddlewareRegistration.lane("private", []))
        let response = await TestClient(dispatch: module.dispatch).get("/page")
        #expect(response.header("X-Frame-Options") == "SAMEORIGIN")
        #expect(response.header("X-Content-Type-Options") == "nosniff")
    }
}
