/// An error that means "a dependency cannot serve this right now; the same
/// request may succeed later" — a database that is unreachable, a pool with
/// nothing free.
///
/// It says nothing about HTTP, because the errors that need it live below the
/// web layer: `DataSourceError` is declared in Alula Data, which cannot
/// depend on `AlulaWeb`. `AlulaWeb` renders a conforming error as
/// `503 Service Unavailable` with `Retry-After`, where it used to be an
/// opaque 500 that told a client nothing and an operator the wrong thing
/// (Relay #42). An `ErrorMapper` still answers first, so an application can
/// render it differently.
///
/// An enum where only some cases are temporary answers per case through
/// ``isTemporarilyUnavailable``.
public protocol TemporarilyUnavailable: Error {
    /// Whether this particular error is temporary. `true` unless a
    /// conformance says otherwise.
    var isTemporarilyUnavailable: Bool { get }
    /// How long a client should wait before trying again, if known.
    var retryAfter: Duration? { get }
}

extension TemporarilyUnavailable {
    public var isTemporarilyUnavailable: Bool { true }
    public var retryAfter: Duration? { nil }
}
