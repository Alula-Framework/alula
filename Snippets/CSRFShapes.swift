// Every shape Docs/web.md's CSRF section claims, compiled.
//
// A doc example that does not compile costs a reader the time to find out.
// This builds as part of `swift build`, so a rename that invalidates the
// prose breaks the build.

import FlightCore
import FlightSessions
import FlightWeb

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
