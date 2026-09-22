import FlightCore
import FlightWeb
import Foundation
import HTTPTypes
import Logging

extension RequestContext {
    /// A ready-made context for exercising middleware and handlers without any
    /// transport. Handlers inject their dependencies (constructed for the
    /// test), so a context no longer carries a container to resolve from.
    ///
    /// `session:` hands the handler a session the way the `Sessions`
    /// middleware would — `Session()` for an empty one, or one built from a
    /// `SessionRecord` to stage a signed-in visitor. Nil, the default, is a
    /// request no session middleware saw.
    ///
    /// `remoteAddress:` stands in for the socket peer no mock has. With no
    /// `TrustedProxies` configured — the default everywhere, `.none` — this
    /// is exactly what `context.clientAddress` returns.
    public static func mock(
        method: HTTPRequest.Method = .get,
        path: String = "/",
        headers: HTTPFields = [:],
        body: Data = Data(),
        pathParameters: [String: String] = [:],
        session: Session? = nil,
        remoteAddress: PeerAddress? = nil
    ) -> RequestContext {
        var logger = Logger(label: "flight.web.test")
        logger.logLevel = .critical
        return RequestContext(
            request: Request(
                method: method, path: path, headers: headers, body: body,
                remoteAddress: remoteAddress),
            pathParameters: pathParameters,
            session: session,
            logger: logger,
            tracingContext: .topLevel
        )
    }
}
