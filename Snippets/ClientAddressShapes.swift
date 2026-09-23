// Every shape Docs/client-address.md claims, compiled.
//
// A doc example that does not compile costs a reader the time to find out.
// This builds as part of `swift build`, so a rename that invalidates the
// prose breaks the build.

import AlulaCore
import AlulaTransport
import AlulaWeb
import AlulaWebTesting

@Controller("/")
private struct WhoAmIController {
    @GetRoute("/")
    func index(_ context: RequestContext) -> String {
        "hello, \(context.clientAddress?.host ?? "unknown visitor")"
    }
}

func clientAddressShapes(configuration: Configuration, routes: [RouteRegistration]) throws {
    let context = RequestContext.mock()
    _ = context.request.remoteAddress
    _ = context.clientAddress

    let proxies = try TrustedProxies(cidrs: ["10.0.0.0/8"])
    let module = try AlulaWebModule<AlulaTransport>(
        configuration: configuration, routes: routes, trustedProxies: proxies)
    _ = module

    // The escape hatch this doc names: reading RFC 7239's Forwarded header
    // directly, since nothing here parses it.
    _ = context.request.headers[.forwarded]
}
