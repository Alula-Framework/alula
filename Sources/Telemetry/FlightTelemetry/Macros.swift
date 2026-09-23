/// Declares a telemetry event: a caseless enum named for what happened.
///
/// ```swift
/// @TelemetryEvent("hangar.query")
/// public enum HangarQuery {
///     public struct Measurements { public var duration: Duration; public var rows: Int }
///     public struct Metadata { public var table: String }
/// }
///
/// Telemetry.emit(HangarQuery.self) { (.init(duration: elapsed, rows: 3), .init(table: "users")) }
/// ```
///
/// The macro conforms the enum to ``TelemetryEvent`` and makes each nested
/// struct encode itself: `Measurements` as numbers (``TelemetryMeasurement``),
/// `Metadata` as values (``TelemetryValue``). Either may be left out. The
/// name is checked at build time. Every field is named for the metrics and
/// logs that see it by its property name, snake_cased: `errorType` is
/// `error_type`.
@attached(member, names: named(name), named(_slot))
@attached(memberAttribute)
@attached(extension, conformances: TelemetryEvent)
public macro TelemetryEvent(_ name: StaticString) =
    #externalMacro(module: "FlightTelemetryMacrosImpl", type: "TelemetryEventMacro")

/// Declares a span: an operation with a start, and a stop or an exception.
///
/// ```swift
/// @TelemetrySpan("hangar.query", kind: .client)
/// public enum HangarQuery {
///     public struct Metadata { public var table: String }
///     public struct StopMetadata { public var rows: Int = 0 }
/// }
///
/// let rows = try await Telemetry.span(HangarQuery.self, metadata: .init(table: "users")) { span in
///     let rows = try await run()
///     span.stopMetadata.rows = rows.count
///     return rows
/// }
/// ```
///
/// Generates the ``SpanEvent`` conformance and three phase events —
/// `HangarQuery.Start`, `.Stop`, `.Exception` — each with its own handlers.
/// `Stop` carries the span's metadata and the stop metadata as one flat
/// struct; `Exception` adds `errorType` between them. `StopMetadata` is
/// optional, and every one of its fields needs a default.
@attached(
    member,
    names: named(name), named(_spanFlags), named(kind), named(Metadata), named(Start), named(Stop),
    named(Exception),
    named(initialStopMetadata), named(stopMetadata), named(exceptionMetadata))
@attached(memberAttribute)
@attached(extension, conformances: SpanEvent)
public macro TelemetrySpan(_ name: StaticString, kind: TelemetrySpanKind = .internal) =
    #externalMacro(module: "FlightTelemetryMacrosImpl", type: "TelemetrySpanMacro")

// flight:not-a-component — the `init` is a fields struct's memberwise
// initializer; nothing here is composed.
/// Makes a struct's stored properties an event's metadata.
///
/// `@TelemetryEvent` and `@TelemetrySpan` apply it to their nested
/// `Metadata` and `StopMetadata`; write it yourself on a struct shared by
/// several events. Each property must be a ``TelemetryValue``. A public
/// struct gets a public memberwise initializer.
@attached(extension, conformances: TelemetryFields, names: named(encode), named(fieldName))
@attached(member, names: named(init))
public macro TelemetryFields() =
    #externalMacro(module: "FlightTelemetryMacrosImpl", type: "TelemetryFieldsMacro")

// flight:not-a-component — the `init` is a fields struct's memberwise
// initializer; nothing here is composed.
/// Makes a struct's stored properties an event's measurements — the numbers
/// metrics aggregate. Each property must be a ``TelemetryMeasurement``: an
/// integer, a `Double`, or a `Duration`.
@attached(extension, conformances: TelemetryFields, names: named(encode), named(fieldName))
@attached(member, names: named(init))
public macro TelemetryMeasurements() =
    #externalMacro(module: "FlightTelemetryMacrosImpl", type: "TelemetryMeasurementsMacro")
