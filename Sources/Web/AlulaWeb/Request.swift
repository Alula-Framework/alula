import Foundation
import HTTPTypes

/// An HTTP request as Alula Web sees it (§2, §5): the parsed head from
/// HTTPTypes plus a fully buffered body. Transports produce these at the
/// byte boundary; nothing downstream re-parses raw HTTP.
///
/// The body is buffered by default (the transport enforces a size cap and
/// rejects oversized bodies with 413 before dispatch ever runs); a route
/// that takes `body: RequestBodyStream` opts into streaming delivery, and
/// its bytes arrive via ``bodyStream`` instead.
public struct Request: Sendable {
    /// Method, target, and header fields — HTTPTypes' representation (§5).
    public var head: HTTPRequest
    /// The complete request body. Empty for bodyless requests — and empty
    /// for streaming-bodied routes, whose bytes arrive via ``bodyStream``.
    public var body: Data
    var _bodyStream: BodyStreamBox?

    /// Who actually opened the TCP connection this request arrived on —
    /// the kernel's answer, not a header's. `nil` for a request with no
    /// real socket behind it: `TestClient`, a hand-built `Request` in a
    /// snippet, `.mock()`.
    ///
    /// This is **not** "the client's address" when a reverse proxy sits in
    /// front of this process — it is the proxy's address, which is
    /// correct and exactly the point: nothing here can be spoofed by a
    /// header. ``RequestContext/clientAddress`` is the one that accounts
    /// for a configured proxy; reach for this only when the raw peer is
    /// genuinely what you want, such as deciding whether to trust the
    /// header in the first place.
    ///
    /// Boxed behind a reference: `Request` is copied per middleware layer
    /// through `RequestContext`, and `PeerAddress`'s `String` would have
    /// pushed that struct back over the two-cache-line bound
    /// `RequestContextLayoutTests` pins — the same reasoning `Session`
    /// already applies to itself. The public shape is unaffected; this is
    /// storage, not API.
    public var remoteAddress: PeerAddress? {
        get { _remoteAddress?.value }
        set { _remoteAddress = newValue.map(RemoteAddressBox.init) }
    }
    private var _remoteAddress: RemoteAddressBox?

    public init(head: HTTPRequest, body: Data = Data(), remoteAddress: PeerAddress? = nil) {
        self.head = head
        self.body = body
        self._remoteAddress = remoteAddress.map(RemoteAddressBox.init)
    }

    /// Convenience initializer used by tests and in-process clients.
    public init(
        method: HTTPRequest.Method = .get,
        path: String,
        headers: HTTPFields = [:],
        body: Data = Data(),
        remoteAddress: PeerAddress? = nil
    ) {
        self.head = HTTPRequest(
            method: method,
            scheme: nil,
            authority: nil,
            path: path,
            headerFields: headers
        )
        self.body = body
        self._remoteAddress = remoteAddress.map(RemoteAddressBox.init)
    }

    // MARK: - Head accessors

    public var method: HTTPRequest.Method { head.method }
    public var headers: HTTPFields { head.headerFields }

    /// The full request target as sent, query string included ("/users?x=1").
    public var uri: String { head.path ?? "/" }

    /// The path component only, percent-encoding left intact — the router
    /// decodes per segment so an encoded "/" cannot change route structure.
    public var path: String {
        let target = uri
        if let separator = target.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            return String(target[..<separator])
        }
        return target
    }

    // MARK: - Query

    /// Query items in order of appearance, percent-decoded. Repeated keys are
    /// preserved ("?tag=a&tag=b" yields two entries).
    public var queryItems: [(name: String, value: String)] {
        Self.queryPairs(of: uri).compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = Self.decodeQueryComponent(parts[0]) else { return nil }
            let value = parts.count > 1 ? Self.decodeQueryComponent(parts[1]) : ""
            guard let value else { return nil }
            return (name, value)
        }
    }

    /// First value for a query parameter, or nil.
    ///
    /// Scans the query string for the name rather than going through
    /// ``queryItems``, which decodes and allocates every pair — a handler
    /// reading three parameters parsed the whole query three times and threw
    /// away three arrays.
    public func queryParam(_ name: String) -> String? {
        for pair in Self.queryPairs(of: uri) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard Self.decodeQueryComponent(parts[0]) == name else { continue }
            return parts.count > 1 ? Self.decodeQueryComponent(parts[1]) : ""
        }
        return nil
    }

    /// The query string as sent, without the leading `?` and without any
    /// fragment — the form-encoded text `decodeQuery` reads.
    ///
    /// Empty when the URI carries no query, which decodes to a type whose
    /// properties are all optional and fails for one that requires a key.
    public var rawQuery: String {
        guard let start = uri.firstIndex(of: "?") else { return "" }
        var query = uri[uri.index(after: start)...]
        if let fragment = query.firstIndex(of: "#") { query = query[..<fragment] }
        return String(query)
    }

    /// The undecoded `name=value` runs of a URI's query, in order.
    private static func queryPairs(of target: String) -> [Substring] {
        guard let queryStart = target.firstIndex(of: "?") else { return [] }
        var query = target[target.index(after: queryStart)...]
        if let fragmentStart = query.firstIndex(of: "#") {
            query = query[..<fragmentStart]
        }
        guard !query.isEmpty else { return [] }
        return query.split(separator: "&", omittingEmptySubsequences: true)
    }

    /// application/x-www-form-urlencoded semantics: "+" is a space.
    private static func decodeQueryComponent(_ component: Substring) -> String? {
        component
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding
    }
}
