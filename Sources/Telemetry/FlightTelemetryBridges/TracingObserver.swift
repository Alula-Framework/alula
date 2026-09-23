import ServiceContextModule
import TelemetryCore
import Tracing

/// Turns telemetry spans into swift-distributed-tracing spans — exported by
/// swift-otel, or whatever tracer the application bootstrapped.
///
/// ```swift
/// let token = try Telemetry.observeSpans(prefix: "hangar", id: "tracing", TracingObserver())
/// ```
///
/// - **start** starts a span named after the event, of the event's
///   `SpanEvent/kind`, with the metadata as attributes — and writes it
///   into the context the body runs in, so it parents every span, traced or
///   telemetry, created inside.
/// - **stop** adds the stop metadata as attributes and ends it.
/// - **exception** records the error, sets the status to `.error`, and ends
///   it.
public struct TracingObserver: SpanObserver {
    private let tracer: (any Tracer)?

    /// - Parameter tracer: The tracer to use. `InstrumentationSystem.tracer`
    ///   — read when each span starts, so bootstrapping after this is
    ///   constructed still works — unless one is given.
    public init(tracer: (any Tracer)? = nil) {
        self.tracer = tracer
    }

    public func start(_ span: borrowing SpanStart, context: inout ServiceContext) -> SpanBox {
        let tracer = self.tracer ?? InstrumentationSystem.tracer
        let traced: any Span = tracer.startSpan(
            span.name.description, context: context, ofKind: Self.kind(span.kind))
        span.forEachMetadata { name, value in traced.attributes[name] = Self.attribute(value) }
        context = traced.context
        return SpanBox(span: traced)
    }

    public func stop(_ span: borrowing SpanStop, state: consuming SpanBox) {
        let traced = state.span
        span.forEachMetadata { name, value in traced.attributes[name] = Self.attribute(value) }
        traced.end()
    }

    public func exception(_ span: borrowing SpanFailure, state: consuming SpanBox) {
        let traced = state.span
        span.forEachMetadata { name, value in traced.attributes[name] = Self.attribute(value) }
        traced.recordError(span.error)
        traced.setStatus(SpanStatus(code: .error))
        traced.end()
    }

    /// The tracing span, carried from start to stop.
    public struct SpanBox: Sendable {
        let span: any Span
    }

    static func kind(_ kind: TelemetrySpanKind) -> SpanKind {
        switch kind {
        case .internal: .internal
        case .server: .server
        case .client: .client
        case .producer: .producer
        case .consumer: .consumer
        }
    }

    static func attribute(_ value: any TelemetryValue) -> SpanAttribute {
        switch value.telemetryPrimitive {
        case .string(let string): .string(string)
        case .integer(let integer): .int64(integer)
        case .double(let double): .double(double)
        case .bool(let bool): .bool(bool)
        }
    }
}
