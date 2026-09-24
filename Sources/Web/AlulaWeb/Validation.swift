import Foundation
import HTTPTypes

/// A request body or query type that checks itself after decoding.
///
/// ```swift
/// struct Signup: Decodable, Validatable {
///     let name: String
///     let email: String
///     let age: Int
///
///     func validate(_ v: inout Validation) {
///         v.check("name", name, .notBlank, .length(max: 80))
///         v.check("email", email, .email)
///         v.check("age", age, .range(13...130))
///     }
/// }
///
/// @PostRoute("/signup")
/// func signup(_ context: RequestContext, body: Signup) async throws -> Response { … }
/// ```
///
/// A `body:` or `query:` parameter whose type is `Validatable` is validated
/// before the handler runs. Every failing field is reported at once, as a
/// `422` whose problem+json carries an `errors` array, so a client fixing a
/// form is not told about one field per round trip.
///
/// Decoding checks shape (this is a number, this key exists). `validate`
/// checks meaning (this number is a plausible age). Keep them apart and the
/// messages stay specific: a missing field is a 400 from decoding, an
/// implausible one a 422 from here.
public protocol Validatable {
    func validate(_ v: inout Validation)
}

/// One field that failed, as the client sees it.
public struct FieldError: Sendable, Equatable, Codable {
    /// The field's name as the client sent it: `email`, `items[2].quantity`.
    public let field: String
    public let message: String

    public init(field: String, message: String) {
        self.field = field
        self.message = message
    }
}

/// Collects failures while a ``Validatable`` checks itself.
public struct Validation: Sendable {
    public private(set) var errors: [FieldError] = []
    private let prefix: String

    public init() { self.prefix = "" }
    private init(prefix: String) { self.prefix = prefix }

    public var isValid: Bool { errors.isEmpty }

    /// Records `message` against `field` unless `condition` holds.
    public mutating func require(_ condition: Bool, _ field: String, _ message: String) {
        if !condition { errors.append(FieldError(field: prefix + field, message: message)) }
    }

    /// Applies `rules` to `value` in order, recording the first that fails,
    /// so a blank field is "must not be blank" rather than also "too short".
    public mutating func check<Value>(_ field: String, _ value: Value, _ rules: ValidationRule<Value>...) {
        for rule in rules {
            if let message = rule.check(value) {
                errors.append(FieldError(field: prefix + field, message: message))
                return
            }
        }
    }

    /// Like `check`, for an optional field: absent passes, present must pass
    /// the rules. To demand presence, make the property non-optional, so
    /// decoding answers 400 for a missing key.
    public mutating func check<Value>(
        _ field: String, _ value: Value?, _ rules: ValidationRule<Value>...
    ) {
        guard let value else { return }
        for rule in rules {
            if let message = rule.check(value) {
                errors.append(FieldError(field: prefix + field, message: message))
                return
            }
        }
    }

    /// Validates a nested value, its errors reported under `field.`.
    public mutating func nested(_ field: String, _ value: some Validatable) {
        var inner = Validation(prefix: prefix + field + ".")
        value.validate(&inner)
        errors += inner.errors
    }

    /// Validates each element, its errors reported under `field[index].`.
    public mutating func each(_ field: String, _ values: [some Validatable]) {
        for (index, value) in values.enumerated() {
            var inner = Validation(prefix: prefix + "\(field)[\(index)].")
            value.validate(&inner)
            errors += inner.errors
        }
    }
}

/// One check on a value: a message when it fails, nil when it passes.
public struct ValidationRule<Value>: Sendable {
    public let check: @Sendable (Value) -> String?

    public init(_ check: @escaping @Sendable (Value) -> String?) {
        self.check = check
    }

    /// A rule from a condition and the message to give when it is false.
    public static func that(_ message: String, _ condition: @escaping @Sendable (Value) -> Bool)
        -> ValidationRule
    {
        ValidationRule { condition($0) ? nil : message }
    }
}

extension ValidationRule where Value == String {
    /// Not empty, and not only whitespace.
    public static var notBlank: ValidationRule {
        .that("must not be blank") { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Length in characters, as a person counts them.
    public static func length(min: Int? = nil, max: Int? = nil) -> ValidationRule {
        ValidationRule { value in
            if let min, value.count < min { return "must be at least \(min) characters" }
            if let max, value.count > max { return "must be at most \(max) characters" }
            return nil
        }
    }

    /// A plausible address: one `@`, something either side, a dot in the
    /// domain, no whitespace. Deliverability is for a confirmation email to
    /// prove; this only catches typing mistakes.
    public static var email: ValidationRule {
        .that("must be an email address") { value in
            let parts = value.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
                && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
                && !value.contains(where: \.isWhitespace)
        }
    }

    /// One of a fixed set.
    public static func oneOf(_ allowed: Set<String>) -> ValidationRule {
        let listed = allowed.sorted().joined(separator: ", ")
        return .that("must be one of: \(listed)") { allowed.contains($0) }
    }

    /// Matches a regular expression in full.
    public static func matches(_ pattern: String, _ message: String = "has an invalid format")
        -> ValidationRule
    {
        .that(message) { value in
            value.range(of: "^(?:\(pattern))$", options: .regularExpression) != nil
        }
    }
}

extension ValidationRule where Value: Comparable & Sendable {
    public static func range(_ bounds: ClosedRange<Value>) -> ValidationRule {
        .that("must be between \(bounds.lowerBound) and \(bounds.upperBound)") { bounds.contains($0) }
    }

    public static func min(_ bound: Value) -> ValidationRule {
        .that("must be at least \(bound)") { $0 >= bound }
    }

    public static func max(_ bound: Value) -> ValidationRule {
        .that("must be at most \(bound)") { $0 <= bound }
    }
}

extension ValidationRule where Value: Collection & Sendable {
    public static var notEmpty: ValidationRule {
        .that("must not be empty") { !$0.isEmpty }
    }

    public static func count(min: Int? = nil, max: Int? = nil) -> ValidationRule {
        ValidationRule { value in
            if let min, value.count < min { return "must have at least \(min) items" }
            if let max, value.count > max { return "must have at most \(max) items" }
            return nil
        }
    }
}

/// Every field that failed validation. A `422 Unprocessable Content`, and
/// under the default renderer an RFC 9457 problem whose `errors` extension
/// member lists each field:
///
/// ```json
/// {"status": 422, "title": "Unprocessable Content",
///  "detail": "2 fields are invalid",
///  "errors": [{"field": "email", "message": "must be an email address"},
///             {"field": "age", "message": "must be between 13 and 130"}]}
/// ```
public struct ValidationFailure: HTTPErrorRepresentable, Sendable, Equatable {
    public let errors: [FieldError]

    public init(errors: [FieldError]) {
        self.errors = errors
    }

    public var httpStatus: HTTPResponse.Status { .unprocessableContent }

    /// The summary, with each field listed, so a renderer that knows nothing
    /// of `errors` still says everything.
    public var httpMessage: String {
        let listed = errors.map { "\($0.field) \($0.message)" }.joined(separator: "; ")
        return errors.count == 1 ? listed : "\(errors.count) fields are invalid: \(listed)"
    }
}

extension Validatable {
    /// Throws ``ValidationFailure`` listing every failing field.
    public func validated() throws {
        var validation = Validation()
        validate(&validation)
        guard validation.isValid else { throw ValidationFailure(errors: validation.errors) }
    }
}

/// Runs `Validatable` on a decoded value, if it is one. Decoding is generic
/// over `Decodable`, so this is the one place the conformance can be seen.
func validateIfValidatable(_ value: Any) throws {
    if let value = value as? any Validatable { try value.validated() }
}
