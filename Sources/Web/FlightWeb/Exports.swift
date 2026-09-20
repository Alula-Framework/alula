import HTTPTypes

/// Re-exported so `import FlightWeb` brings the HTTP vocabulary —
/// `HTTPRequest.Method`, `HTTPFields`, `HTTPField.Name`, `Status` — without
/// a second import, the same way FlightCore re-exports FlightConfig.
@_exported import struct HTTPTypes.HTTPRequest
@_exported import struct HTTPTypes.HTTPResponse
@_exported import struct HTTPTypes.HTTPField
@_exported import struct HTTPTypes.HTTPFields

/// Encodes a handler's return value (§4). A free function rather than a
/// bare method call in the macro expansion so a non-conforming return type
/// fails with a diagnostic that names `ResponseEncodable` at the handler.
public func encodeResponse<T: ResponseEncodable>(
    _ value: T,
    for context: RequestContext
) throws -> Response {
    try value.response(for: context)
}

/// Never called. It exists so that the overwhelmingly common mistake — a
/// `Codable` model returned from a handler, without `ResponseEncodable` in
/// its conformance list — produces an instruction instead of a constraint.
///
/// Swift cannot make every `Encodable` type conform to `ResponseEncodable`
/// (a protocol cannot be extended to conform to another), so the conformance
/// has to be written out. It needs no members: the default implementation on
/// `ResponseEncodable where Self: Encodable` supplies everything. What used
/// to be left to the reader was *that* — the error said only
///
///     requires that 'User' conform to 'ResponseEncodable'
///
/// from inside a macro expansion the reader did not write.
///
/// Overload resolution prefers the constrained function above whenever it
/// applies, so a type that does conform never reaches this one.
@available(
    *, unavailable,
    message: """
        This type is Encodable but not ResponseEncodable. Add it to the \
        conformance list — it needs no members, because Encodable supplies \
        them: `struct User: Codable, ResponseEncodable {}`.
        """
)
public func encodeResponse<T: Encodable>(
    _ value: T,
    for context: RequestContext
) throws -> Response {
    // Unreachable: calling an unavailable function is a compile error, which
    // is the entire point of the declaration.
    fatalError("unavailable")
}

extension RouteRegistration {
    /// Codegen convenience: macro expansions carry the method as the literal
    /// they validated ("GET"); user code should prefer the typed initializer.
    public init(
        method: String,
        path: String,
        kind: Kind = .http,
        source: String = "<direct>",
        pipelines: [PipelineLane] = [.default],
        bodyMode: BodyMode = .buffered(maxBytes: nil),
        handler: @escaping @Sendable (RequestContext) async throws -> Response
    ) {
        // A method string this does not recognize is a build-generator bug
        // or a typo, and `?? .get` turned either into a *live GET route* —
        // reachable, wrong, and silent. Everything else about the route table
        // fails at startup; so does this.
        guard let parsed = HTTPRequest.Method(method) else {
            preconditionFailure(
                """
                Route \(source) declares HTTP method "\(method)" for \(path), which is not a \
                valid method token. Registering it as GET — which is what used to happen — \
                would publish a route nobody asked for.
                """)
        }
        self.init(
            method: parsed,
            path: path,
            kind: kind,
            source: source,
            pipelines: pipelines,
            bodyMode: bodyMode,
            handler: handler
        )
    }
}
