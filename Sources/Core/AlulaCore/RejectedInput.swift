/// An error that means "the request asked for something malformed" — a
/// filter on a field that cannot be filtered, a value of the wrong type.
///
/// Status-neutral, like ``TemporarilyUnavailable``, so packages below the
/// web layer can conform: Alula Data conforms Hangar's dynamic-filter errors.
/// `AlulaWeb` renders a conforming error as `400 Bad Request` with
/// ``rejectionMessage``; it used to be an opaque 500, which told the client
/// the server had failed when the client had asked wrongly.
public protocol RejectedInput: Error {
    /// Whether this particular error is the request's fault. `true` unless
    /// a conformance says otherwise.
    var isRejectedInput: Bool { get }
    /// What the client is told. It reaches the wire, so it must say only
    /// what the request itself said — never a table name or a value from
    /// the database.
    var rejectionMessage: String { get }
}

extension RejectedInput {
    public var isRejectedInput: Bool { true }
}
