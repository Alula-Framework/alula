/// An event seen without its type: its name, its context, and its fields by
/// visitor.
///
/// A borrowed view over the typed payload — building one boxes nothing, and
/// reading a field goes through the event's own `encode(into:)`. It is
/// noncopyable and handed to handlers `borrowing`, so it cannot outlive the
/// dispatch it describes.
public struct AnyEvent: ~Copyable {
    public let context: EventContext
    @usableFromInline let payload: any ErasedPayload

    /// The event's name — read from its type only when asked.
    public var name: EventName { payload.name }

    /// Borrows `context`'s frame: the view it makes lives no longer than
    /// the dispatch, and so does this one.
    @usableFromInline
    init(context: borrowing EventContext, payload: any ErasedPayload) {
        self.context = EventContext(frame: context.frame)
        self.payload = payload
    }

    /// Each measurement, in declaration order.
    public func forEachMeasurement(_ body: (String, any TelemetryMeasurement) -> Void) {
        withoutActuallyEscaping(body) { body in
            var encoder = FieldEncoder(measurement: body, value: { _, _ in })
            payload.encodeMeasurements(into: &encoder)
        }
    }

    /// Each metadata field, in declaration order; absent optionals skipped.
    public func forEachMetadata(_ body: (String, any TelemetryValue) -> Void) {
        withoutActuallyEscaping(body) { body in
            var encoder = FieldEncoder(measurement: { _, _ in }, value: body)
            payload.encodeMetadata(into: &encoder)
        }
    }
}

/// The typed payload behind an ``AnyEvent``: two pointers, which fit an
/// existential's inline buffer, so erasing costs no allocation.
@usableFromInline
protocol ErasedPayload {
    var name: EventName { get }
    func encodeMeasurements(into encoder: inout FieldEncoder)
    func encodeMetadata(into encoder: inout FieldEncoder)
}

@usableFromInline
struct TypedPayload<E: TelemetryEvent>: ErasedPayload {
    let measurements: UnsafePointer<E.Measurements>
    let metadata: UnsafePointer<E.Metadata>

    @usableFromInline
    init(measurements: UnsafePointer<E.Measurements>, metadata: UnsafePointer<E.Metadata>) {
        self.measurements = measurements
        self.metadata = metadata
    }

    @usableFromInline
    var name: EventName { E.name }

    @usableFromInline
    func encodeMeasurements(into encoder: inout FieldEncoder) {
        measurements.pointee.encode(into: &encoder)
    }

    @usableFromInline
    func encodeMetadata(into encoder: inout FieldEncoder) {
        metadata.pointee.encode(into: &encoder)
    }
}
