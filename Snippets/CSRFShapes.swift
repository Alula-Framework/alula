// Every shape Docs/web.md's CSRF section claims, compiled.
//
// A doc example that does not compile costs a reader the time to find out.
// This builds as part of `swift build`, so a rename that invalidates the
// prose breaks the build.

import AlulaCore
import AlulaSessions
import AlulaWeb

struct TransferForm: Encodable, ResponseEncodable {
    let csrfToken: String
}

@Controller("/")
private struct TransferController {
    @GetRoute("/transfer")
    func form(_ context: RequestContext) throws -> TransferForm {
        TransferForm(csrfToken: try context.requireSession().csrfToken())
    }

    @PostRoute("/transfer")
    func submit(_ context: RequestContext) async throws -> Response {
        .status(.noContent)
    }
}

func csrfShapes(sessionsRuntime: SessionRuntime) {
    _ = MiddlewareRegistration.lane(
        .default,
        [
            Sessions(runtime: sessionsRuntime),
            CSRFProtection(),
        ])
}

// Login CSRF: an anonymous GET mints the token; sign-in names the lane.
struct CSRFTokenResponse: Encodable, ResponseEncodable {
    let csrfToken: String
}

struct SignIn: Decodable {
    let token: String
}

@Controller("/session")
private struct SignInController {
    @GetRoute("/csrf")
    func csrf(_ context: RequestContext) throws -> CSRFTokenResponse {
        CSRFTokenResponse(csrfToken: try context.requireSession().csrfToken())
    }

    @PostRoute("/", pipelines: [.default, "csrf"])
    func signIn(_ context: RequestContext, body: SignIn) async throws -> Response {
        .status(.noContent)
    }
}
