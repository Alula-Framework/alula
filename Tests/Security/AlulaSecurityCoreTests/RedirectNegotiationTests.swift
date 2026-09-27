import AlulaWeb
import AlulaWebTesting
import Foundation
import HTTPTypes
import Testing

@testable import AlulaSecurityCore

@Suite("Sign-in and sign-out redirects a script can follow")
struct RedirectNegotiationTests {
    static let logout = URL(string: "https://id.example.com/logout?id_token_hint=x")!

    func context(accept: String?, method: HTTPRequest.Method = .delete) -> RequestContext {
        var headers = HTTPFields()
        if let accept { headers[.accept] = accept }
        return .mock(method: method, path: "/api/session", headers: headers)
    }

    @Test("a script is told where to go: 200 with the URL, which it can read")
    func scriptGetsJSON() throws {
        // Relay #22: a DELETE from fetch could not follow the provider's
        // logout 303 — cross-origin under CORS, or opaque with redirect:
        // "manual" — so a single-page app could not end the provider session.
        for accept in ["application/json", "*/*", "application/json, text/plain"] {
            let response = try SignOutStep.redirect(Self.logout).response(
                for: context(accept: accept))
            #expect(response.status == .ok, "Accept: \(accept)")
            let body =
                try JSONSerialization.jsonObject(with: Data(response.bodyText.utf8))
                as? [String: String]
            #expect(body?["redirect"] == Self.logout.absoluteString)
        }
    }

    @Test("a browser navigating is sent there, as before")
    func browserGetsRedirect() throws {
        for accept in ["text/html,application/xhtml+xml,*/*;q=0.8", nil] {
            let response = try SignOutStep.redirect(Self.logout).response(
                for: context(accept: accept, method: .get))
            #expect(response.status == .seeOther)
            #expect(response.headers[.location] == Self.logout.absoluteString)
        }
    }

    @Test("sign-in steps and results negotiate the same way; nothing to follow stays 204")
    func signInToo() throws {
        let script = context(accept: "application/json", method: .get)
        #expect(try SignInStep.redirect(Self.logout).response(for: script).status == .ok)
        #expect(
            try SignInResult(principal: Principal(subject: "u", issuer: "test"), returnTo: "/home")
                .response(for: script).status == .ok)
        #expect(
            try SignInResult(principal: Principal(subject: "u", issuer: "test")).response(
                for: script
            ).status == .noContent)
        #expect(try SignOutStep.done.response(for: script).status == .noContent)
    }
}
