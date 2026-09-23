import Foundation

/// A number an event reports: what a metric aggregates — a duration, a row
/// count, a byte size. Only these can be a `Distribution` or a `Sum`'s field;
/// anything else is metadata.
public protocol TelemetryMeasurement: TelemetryValue {
    /// The value as a reporter reads it.
    var measurementValue: MeasurementValue { get }
}

/// A measurement's value in one of the three shapes a metrics backend
/// distinguishes.
public enum MeasurementValue: Sendable, Equatable {
    case integer(Int64)
    case double(Double)
    case duration(Duration)

    /// As a floating-point number — nanoseconds for a duration.
    public var doubleValue: Double {
        switch self {
        case .integer(let value): Double(value)
        case .double(let value): value
        case .duration(let value):
            Double(value.components.seconds) * 1e9 + Double(value.components.attoseconds) / 1e9
        }
    }
}

/// Anything an event may carry: measurements, and the metadata a handler
/// slices by or logs.
public protocol TelemetryValue: Sendable {
    /// How a log line or an erased handler shows it.
    var telemetryDescription: String { get }

    /// The value as a backend's attribute type — a tracing attribute, a
    /// structured log field. A string unless the type says otherwise.
    var telemetryPrimitive: TelemetryPrimitive { get }
}

extension TelemetryValue {
    public var telemetryPrimitive: TelemetryPrimitive { .string(telemetryDescription) }
}

/// The attribute types tracing and logging backends share.
public enum TelemetryPrimitive: Sendable, Hashable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
}

/// A metadata value a metric may be tagged by. A closed, low-cardinality
/// set is the contract: a route pattern, an outcome, a table — never an id,
/// a user, or an address.
public protocol TagValue: TelemetryValue {
    var tagValue: String { get }
}

extension Int: TelemetryMeasurement, TagValue {
    public var telemetryPrimitive: TelemetryPrimitive { .integer(Int64(self)) }
    public var measurementValue: MeasurementValue { .integer(Int64(self)) }
    public var telemetryDescription: String { String(self) }
    public var tagValue: String { String(self) }
}

extension Int64: TelemetryMeasurement {
    public var telemetryPrimitive: TelemetryPrimitive { .integer(self) }
    public var measurementValue: MeasurementValue { .integer(self) }
    public var telemetryDescription: String { String(self) }
}

extension UInt64: TelemetryMeasurement {
    public var telemetryPrimitive: TelemetryPrimitive { .integer(Int64(clamping: self)) }
    /// Clamped at `Int64.max`; a counter that large has other problems.
    public var measurementValue: MeasurementValue { .integer(Int64(clamping: self)) }
    public var telemetryDescription: String { String(self) }
}

extension Double: TelemetryMeasurement {
    public var telemetryPrimitive: TelemetryPrimitive { .double(self) }
    public var measurementValue: MeasurementValue { .double(self) }
    public var telemetryDescription: String { String(self) }
}

extension Duration: TelemetryMeasurement {
    public var measurementValue: MeasurementValue { .duration(self) }
    public var telemetryDescription: String { description }
}

extension String: TagValue {
    public var telemetryDescription: String { self }
    public var tagValue: String { self }
}

extension Bool: TagValue {
    public var telemetryPrimitive: TelemetryPrimitive { .bool(self) }
    public var telemetryDescription: String { self ? "true" : "false" }
    public var tagValue: String { telemetryDescription }
}

extension UUID: TelemetryValue {
    public var telemetryDescription: String { uuidString }
}

/// An optional field is encoded only when it has a value — how a library
/// carries something high-cardinality, like a SQL statement, behind an
/// opt-in.
extension Optional: TelemetryValue where Wrapped: TelemetryValue {
    public var telemetryPrimitive: TelemetryPrimitive { self?.telemetryPrimitive ?? .string("nil") }
    public var telemetryDescription: String { self?.telemetryDescription ?? "nil" }
}

/// How the encoder recognizes an absent optional without knowing its type.
public protocol _OptionalTelemetryValue {
    var _isNil: Bool { get }
}

extension Optional: _OptionalTelemetryValue where Wrapped: TelemetryValue {
    public var _isNil: Bool { self == nil }
}

/// A `String`- or `Int`-backed enum declares `TagValue` and gets its raw
/// value as the tag.
extension TagValue where Self: RawRepresentable, RawValue == String {
    public var telemetryDescription: String { rawValue }
    public var tagValue: String { rawValue }
}

extension TagValue where Self: RawRepresentable, RawValue == Int {
    public var telemetryDescription: String { String(rawValue) }
    public var tagValue: String { String(rawValue) }
}

/// A visitor over an event's fields: what `@TelemetryEvent` generates calls
/// into, and what a log bridge or an erased handler reads through. No
/// dictionary is built; each field is handed over once.
public struct FieldEncoder: ~Copyable {
    private let onMeasurement: (String, any TelemetryMeasurement) -> Void
    private let onValue: (String, any TelemetryValue) -> Void

    public init(
        measurement: @escaping (String, any TelemetryMeasurement) -> Void,
        value: @escaping (String, any TelemetryValue) -> Void
    ) {
        self.onMeasurement = measurement
        self.onValue = value
    }

    /// A numeric field. Requiring `TelemetryMeasurement` here is what makes a
    /// non-numeric measurement a compile error at its declaration.
    public mutating func measurement(_ name: String, _ value: some TelemetryMeasurement) {
        onMeasurement(name, value)
    }

    /// A metadata field. An optional that is `nil` is skipped.
    public mutating func value(_ name: String, _ value: some TelemetryValue) {
        if let optional = value as? any _OptionalTelemetryValue, optional._isNil { return }
        onValue(name, value)
    }
}

/// An event's measurements or metadata: stored fields a handler reads by
/// type, and a visitor for handlers that cannot know the type.
///
/// `@TelemetryEvent` writes the conformance; it can be written by hand.
public protocol TelemetryFields: Sendable {
    /// Hands each stored field to `encoder`, once, in declaration order.
    func encode(into encoder: inout FieldEncoder)

    /// The field a key path names, for metric names. Never derived from a
    /// key path's debug description, which is not stable.
    static func fieldName(for keyPath: PartialKeyPath<Self>) -> String?
}

/// No fields: what an event with no measurements, or no metadata, carries.
public struct NoFields: TelemetryFields, Equatable {
    public init() {}
    public func encode(into encoder: inout FieldEncoder) {}
    public static func fieldName(for keyPath: PartialKeyPath<NoFields>) -> String? { nil }
}
