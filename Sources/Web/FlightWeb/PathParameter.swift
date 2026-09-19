import Foundation

// Path parameters as values rather than strings.
//
// A route says `/users/:id` and the handler says `id: UUID`, and the two are
// checked against each other at compile time — a handler asking for a segment
// the path does not declare is a build error naming the ones it does. What
// arrives at the handler has already been parsed, so the first line of every
// handler stops being a guard that unwraps a string and converts it.
//
// The failure that remains is the one that genuinely belongs to the request:
// `/users/not-a-uuid` cannot produce a `UUID`, and that is a 400 naming the
// parameter and the expected type, not a 500 from an unwrap.

/// A type a path segment can be parsed into.
///
/// `String`, the integer types, `Double`, `Bool` and `UUID` conform. Conform
/// your own when a route carries something more specific than its spelling —
/// a `Slug`, a `Tenant`, an enum of allowed names — so the validity of the
/// segment is decided once, at the edge, rather than everywhere it is used.
///
/// ```swift
/// struct Slug: PathParameterConvertible {
///     let value: String
///     init?(pathParameter text: String) {
///         guard text.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" })
///         else { return nil }
///         self.value = text
///     }
/// }
/// ```
public protocol PathParameterConvertible: Sendable {
    /// Parse a raw path segment, or return nil if it is not one of these.
    ///
    /// Returning nil is a 400: the request named something this route cannot
    /// address. Throwing is deliberately not offered — "this segment is not a
    /// UUID" is the whole of what a path parameter can get wrong.
    init?(pathParameter: String)
}

extension String: PathParameterConvertible {
    public init?(pathParameter: String) { self = pathParameter }
}

extension UUID: PathParameterConvertible {
    public init?(pathParameter: String) { self.init(uuidString: pathParameter) }
}

extension Bool: PathParameterConvertible {
    /// The spellings the form decoder accepts, for the same reason: a path
    /// reading `/features/dark-mode/on` should not require the caller to know
    /// which four letters this library prefers.
    public init?(pathParameter: String) {
        switch pathParameter.lowercased() {
        case "true", "1", "on", "yes": self = true
        case "false", "0", "off", "no": self = false
        default: return nil
        }
    }
}

extension PathParameterConvertible where Self: LosslessStringConvertible {
    public init?(pathParameter: String) { self.init(pathParameter) }
}

extension Int: PathParameterConvertible {}
extension Int8: PathParameterConvertible {}
extension Int16: PathParameterConvertible {}
extension Int32: PathParameterConvertible {}
extension Int64: PathParameterConvertible {}
extension UInt: PathParameterConvertible {}
extension UInt64: PathParameterConvertible {}
extension Double: PathParameterConvertible {}
extension Float: PathParameterConvertible {}

extension RequestContext {
    /// A path parameter, parsed.
    ///
    /// ```swift
    /// let id = try context.pathParam("id", as: UUID.self)
    /// ```
    ///
    /// Throws a 400 naming the parameter and the type when the segment is
    /// absent or does not parse. Generated route handlers use this, so a
    /// handler written with typed parameters and one written by hand fail the
    /// same way and say the same thing.
    public func pathParam<Value: PathParameterConvertible>(
        _ name: String, as type: Value.Type
    ) throws -> Value {
        try decodePathParameter(type, named: name, from: self)
    }
}

/// Not user API — what a generated route handler calls.
///
/// Public because the macro expands into the caller's module, where internal
/// would be out of reach. ``RequestContext/pathParam(_:as:)`` is the same
/// thing with a name on it.
public func decodePathParameter<Value: PathParameterConvertible>(
    _ type: Value.Type, named name: String, from context: RequestContext
) throws -> Value {
    guard let raw = context.pathParameters[name] else {
        // Route table and handler disagreeing, which the macro's check makes
        // unreachable for generated handlers — so this is for hand-built
        // contexts, and it says which name it wanted.
        throw HTTPError(.badRequest, "missing path parameter '\(name)'")
    }
    guard let value = Value(pathParameter: raw) else {
        throw HTTPError(
            .badRequest, "path parameter '\(name)' is not a valid \(type): '\(raw)'")
    }
    return value
}

// MARK: - Query parameters as a struct

/// Not user API — what a generated route handler calls for a `query:`
/// parameter.
///
/// The query string is `application/x-www-form-urlencoded`, which is the wire
/// format ``FormDecoder`` already reads, so this is that decoder pointed at a
/// different part of the request rather than a second implementation of the
/// same rules. Repeated keys behave as they do in a form body: an array target
/// collects them, a scalar target takes the last.
///
/// **A missing key is an error for a non-optional property, and that is the
/// intended reading.** Swift's synthesized `Decodable` does not use a
/// property's default value when a key is absent — it throws — so
/// `var page: Int` means the request must carry `page`, and `var page: Int?`
/// means it may. Since absence is ordinary in a query string, most fields
/// want to be optional.
public func decodeQuery<Value: Decodable>(
    _ type: Value.Type, from context: RequestContext
) throws -> Value {
    let query = context.request.rawQuery
    do {
        return try FormDecoder().decode(type, from: Data(query.utf8))
    } catch let error as DecodingError {
        throw HTTPError(.badRequest, queryErrorMessage(error, type: type))
    }
}

/// A decoding failure, said in terms of the query string rather than of
/// `Decodable` — a caller who sent `?page=abc` should be told about `page`.
private func queryErrorMessage<Value>(_ error: DecodingError, type: Value.Type) -> String {
    switch error {
    case .keyNotFound(let key, _):
        return "missing query parameter '\(key.stringValue)'"
    case .typeMismatch(let mismatched, let context), .valueNotFound(let mismatched, let context):
        let name = context.codingPath.last?.stringValue
        return name.map { "query parameter '\($0)' is not a valid \(mismatched)" }
            ?? "invalid query for \(type)"
    case .dataCorrupted(let context):
        let name = context.codingPath.last?.stringValue
        return name.map { "query parameter '\($0)' is malformed" } ?? "malformed query string"
    @unknown default:
        return "invalid query for \(type)"
    }
}

extension RequestContext {
    /// The query string decoded into a type of your own.
    ///
    /// ```swift
    /// let filters = try context.query(ListFilters.self)
    /// ```
    ///
    /// The same decoding a `query:` handler parameter receives, for middleware
    /// and for handlers that take the context alone.
    public func query<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try decodeQuery(type, from: self)
    }
}
