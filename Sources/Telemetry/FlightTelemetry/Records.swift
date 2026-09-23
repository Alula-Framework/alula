/// One emit, kept: what a typed handler saw, as a value that can outlive the
/// dispatch — for a test to assert on, or an async consumer to process.
public struct EventRecord<E: TelemetryEvent>: Sendable {
    public let measurements: E.Measurements
    public let metadata: E.Metadata
    public let context: EventContext.Snapshot

    public init(measurements: E.Measurements, metadata: E.Metadata, context: EventContext.Snapshot)
    {
        self.measurements = measurements
        self.metadata = metadata
        self.context = context
    }

    /// Copies what a handler was handed.
    public init(
        _ measurements: borrowing E.Measurements, _ metadata: borrowing E.Metadata,
        _ context: borrowing EventContext
    ) {
        self.init(
            measurements: copy measurements, metadata: copy metadata, context: context.snapshot())
    }
}

/// One emit, kept, as an erased handler saw it: its name and its fields by
/// name.
public struct AnyEventRecord: Sendable, CustomStringConvertible {
    public let name: EventName
    public let context: EventContext.Snapshot
    /// Measurements in declaration order.
    public let measurements: [(name: String, value: any TelemetryMeasurement)]
    /// Metadata in declaration order; absent optionals are not here.
    public let metadata: [(name: String, value: any TelemetryValue)]

    /// Copies what an erased handler was handed.
    public init(_ event: borrowing AnyEvent) {
        var measurements: [(name: String, value: any TelemetryMeasurement)] = []
        var metadata: [(name: String, value: any TelemetryValue)] = []
        event.forEachMeasurement { measurements.append(($0, $1)) }
        event.forEachMetadata { metadata.append(($0, $1)) }
        self.name = event.name
        self.context = event.context.snapshot()
        self.measurements = measurements
        self.metadata = metadata
    }

    /// A measurement by field name.
    public func measurement(_ name: String) -> (any TelemetryMeasurement)? {
        measurements.first { $0.name == name }?.value
    }

    /// A metadata field's description by field name — `"users"`, `"3"`,
    /// `"true"` — which is what a test usually compares.
    public subscript(metadata name: String) -> String? {
        metadata.first { $0.name == name }?.value.telemetryDescription
    }

    public var description: String {
        let fields =
            measurements.map { "\($0.name)=\($0.value.telemetryDescription)" }
            + metadata.map { "\($0.name)=\($0.value.telemetryDescription)" }
        return fields.isEmpty ? name.description : "\(name) " + fields.joined(separator: " ")
    }
}
