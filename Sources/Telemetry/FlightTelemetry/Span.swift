import ServiceContextModule
import Synchronization

/// An operation with a duration: `start`, then `stop` or `exception`.
///
/// ```swift
/// @TelemetrySpan("flight.http.request")
/// public enum HTTPRequestSpan {
///     public struct Metadata { public var method: String; public var route: String }
///     public struct StopMetadata { public var status: Int = 0 }
/// }
///
/// try await Telemetry.span(HTTPRequestSpan.self, metadata: .init(method: "GET", route: "/users/:id")) { span in
///     let response = try await next(context)
///     span.stopMetadata.status = response.status.code
///     return response
/// }
/// ```
///
/// Each phase is a full ``TelemetryEvent`` with its own name
/// (`flight.http.request.start`, `.stop`, `.exception`) and its own handlers,
/// so a metric targets a phase directly: `Counter(HTTPRequestSpan.Stop.self)`.
/// `@TelemetrySpan` writes the three phase types and this conformance; both
/// can be written by hand.
public protocol SpanEvent: Sendable {
    /// Known when the span starts; on every phase.
    associatedtype Metadata: TelemetryFields = NoFields
    /// Set inside the body through ``SpanHandle/stopMetadata``; on `stop` and
    /// `exception`.
    associatedtype StopMetadata: TelemetryFields = NoFields

    associatedtype Start: TelemetryEvent
    where Start.Measurements == SpanStartMeasurements, Start.Metadata == Metadata
    associatedtype Stop: TelemetryEvent where Stop.Measurements == SpanDurationMeasurements
    associatedtype Exception: TelemetryEvent
    where Exception.Measurements == SpanDurationMeasurements

    static var name: EventName { get }

    /// Whether anything observes the span — the one word a span reads before
    /// deciding to run its body plainly. The macro writes
    /// `static let _spanFlags = SpanFlags()`, and builds each phase's slot
    /// with `HandlerSlot(span: _spanFlags, phase:)`.
    static var _spanFlags: SpanFlags { get }

    /// What a tracing bridge reports the span as.
    static var kind: TelemetrySpanKind { get }

    /// The stop metadata a span begins with, before the body sets anything.
    static func initialStopMetadata() -> StopMetadata

    /// The `stop` phase's metadata: the span's, then the body's.
    static func stopMetadata(_ metadata: Metadata, _ stop: StopMetadata) -> Stop.Metadata

    /// The `exception` phase's metadata: the span's, the error's type, then
    /// whatever the body had set before it threw.
    static func exceptionMetadata(
        _ metadata: Metadata, _ stop: StopMetadata, errorType: String
    ) -> Exception.Metadata
}

extension SpanEvent {
    public static var kind: TelemetrySpanKind { .internal }
}

extension SpanEvent where StopMetadata == NoFields {
    public static func initialStopMetadata() -> NoFields { NoFields() }
}

/// Whether a span is observed: a bit per phase with typed handlers, and the
/// registry's shared bits for erased handlers and span observers.
public final class SpanFlags: Sendable, EnrolledSlot {
    @usableFromInline let flags = Atomic<UInt8>(0)

    public init() {
        Registry.enroll(self)
    }

    func setGlobal(_ bit: UInt8, _ on: Bool) {
        if on {
            flags.bitwiseOr(bit, ordering: .relaxed)
        } else {
            flags.bitwiseAnd(~bit, ordering: .relaxed)
        }
    }
}

/// Which phase of a span a slot belongs to.
public enum SpanPhase: Sendable {
    case start, stop, exception

    var bit: UInt8 {
        switch self {
        case .start: 8
        case .stop: 16
        case .exception: 32
        }
    }
}

/// What a tracing bridge reports a span as — OpenTelemetry's span kinds.
public enum TelemetrySpanKind: Sendable {
    case `internal`, server, client, producer, consumer
}

/// A span's `start` measurement.
public struct SpanStartMeasurements: TelemetryFields {
    /// Monotonic time since an arbitrary process-wide reference — for
    /// ordering starts, not for display.
    public var monotonicTime: Duration

    public init(monotonicTime: Duration) { self.monotonicTime = monotonicTime }

    public func encode(into encoder: inout FieldEncoder) {
        encoder.measurement("monotonic_time", monotonicTime)
    }

    public static func fieldName(for keyPath: PartialKeyPath<Self>) -> String? {
        keyPath == \Self.monotonicTime ? "monotonic_time" : nil
    }

    static let reference = ContinuousClock.now
}

/// A span's `stop` or `exception` measurement.
public struct SpanDurationMeasurements: TelemetryFields {
    public var duration: Duration

    public init(duration: Duration) { self.duration = duration }

    public func encode(into encoder: inout FieldEncoder) {
        encoder.measurement("duration", duration)
    }

    public static func fieldName(for keyPath: PartialKeyPath<Self>) -> String? {
        keyPath == \Self.duration ? "duration" : nil
    }
}

/// Inside a span's body: what the body can add, and the context it runs in.
///
/// Noncopyable and handed over `inout`, so it cannot be kept past the body.
/// (The design wanted it `~Escapable` too; Swift 6.3 cannot construct a
/// nonescapable value without the experimental `Lifetimes` feature. D42
/// records the reproducer.)
public struct SpanHandle<E: SpanEvent>: ~Copyable {
    /// Reported on `stop` and `exception` — a row count, a status code.
    public var stopMetadata: E.StopMetadata
    /// The context the body runs under: the span's id, and whatever an
    /// observer added — a tracing span, say. Nil when nothing observes the
    /// span.
    public let serviceContext: ServiceContext?

    public var spanID: TelemetrySpanID? { serviceContext?.telemetrySpan?.spanID }

    @usableFromInline
    init(stopMetadata: E.StopMetadata, serviceContext: ServiceContext?) {
        self.stopMetadata = stopMetadata
        self.serviceContext = serviceContext
    }
}

// MARK: - Observers

/// A consumer of span lifecycles, for what plain handlers cannot do: carry
/// state from `start` to `stop`, and change the context the body runs under.
/// This is what a tracing bridge is — it starts a tracing span on `start`,
/// makes it the parent of spans inside the body, and ends it on `stop`.
public protocol SpanObserver: Sendable {
    associatedtype State: Sendable

    func start(_ span: borrowing SpanStart, context: inout ServiceContext) -> State
    func stop(_ span: borrowing SpanStop, state: consuming State)
    func exception(_ span: borrowing SpanFailure, state: consuming State)
}

/// A span starting, as an observer sees it.
public struct SpanStart: ~Copyable {
    public let name: EventName
    public let kind: TelemetrySpanKind
    public let spanID: TelemetrySpanID
    public let parentSpanID: TelemetrySpanID?
    let metadata: any ErasedFields

    public func forEachMetadata(_ body: (String, any TelemetryValue) -> Void) {
        metadata.forEachValue(body)
    }
}

/// A span that finished, as an observer sees it.
public struct SpanStop: ~Copyable {
    public let name: EventName
    public let spanID: TelemetrySpanID
    public let duration: Duration
    let metadata: any ErasedFields

    /// The span's metadata, then the body's stop metadata.
    public func forEachMetadata(_ body: (String, any TelemetryValue) -> Void) {
        metadata.forEachValue(body)
    }
}

/// A span whose body threw, as an observer sees it.
public struct SpanFailure: ~Copyable {
    public let name: EventName
    public let spanID: TelemetrySpanID
    public let duration: Duration
    public let error: any Error
    let metadata: any ErasedFields

    public func forEachMetadata(_ body: (String, any TelemetryValue) -> Void) {
        metadata.forEachValue(body)
    }
}

protocol ErasedFields {
    func forEachValue(_ body: (String, any TelemetryValue) -> Void)
}

struct FieldsPointer<F: TelemetryFields>: ErasedFields {
    let pointer: UnsafePointer<F>
    func forEachValue(_ body: (String, any TelemetryValue) -> Void) {
        withoutActuallyEscaping(body) { body in
            var encoder = FieldEncoder(measurement: { _, _ in }, value: body)
            pointer.pointee.encode(into: &encoder)
        }
    }
}

/// A ``SpanObserver`` with its `State` erased: one box per observed span,
/// allocated only when an observer matches.
struct AnySpanObserver: Sendable {
    let start: @Sendable (borrowing SpanStart, inout ServiceContext) -> any SpanRun

    init<O: SpanObserver>(_ observer: O) {
        self.start = { span, context in
            ObservedSpan(observer: observer, state: observer.start(span, context: &context))
        }
    }
}

protocol SpanRun: AnyObject, Sendable {
    func stop(_ span: borrowing SpanStop)
    func exception(_ span: borrowing SpanFailure)
}

final class ObservedSpan<O: SpanObserver>: SpanRun {
    let observer: O
    let state: Lock<O.State?>

    init(observer: O, state: O.State) {
        self.observer = observer
        self.state = Lock(state)
    }

    func stop(_ span: borrowing SpanStop) {
        if let state = state.withLock({ slot -> O.State? in
            defer { slot = nil }
            return slot
        }) {
            observer.stop(span, state: state)
        }
    }

    func exception(_ span: borrowing SpanFailure) {
        if let state = state.withLock({ slot -> O.State? in
            defer { slot = nil }
            return slot
        }) {
            observer.exception(span, state: state)
        }
    }
}

extension Telemetry {
    /// Attaches `observer` to every span whose name lies under `prefix`.
    public static func observeSpans(
        prefix: EventName, id: HandlerID, _ observer: some SpanObserver
    ) throws(AttachError) -> HandlerToken {
        let entry = ObserverEntry(id: id, body: (prefix, AnySpanObserver(observer)))
        try Registry.attachObserver(entry)
        return HandlerToken { Registry.detachObserver(entry) }
    }

    // MARK: Spans

    /// Whether anything observes `E` — any phase handler, an erased handler,
    /// or a span observer. One relaxed load; no clock, no task-local.
    @inlinable
    public static func isObserved<E: SpanEvent>(_: E.Type) -> Bool {
        E._spanFlags.flags.load(ordering: .relaxed) != 0
    }

    /// Runs `body` as span `E`: `start` before it, `stop` after it, or
    /// `exception` if it throws — whose error passes through unchanged.
    ///
    /// Unobserved, `body` runs directly: the metadata is never built and no
    /// context is bound.
    @inlinable
    public static func span<E: SpanEvent, R, Failure: Error>(
        _: E.Type,
        metadata: @autoclosure () -> E.Metadata,
        _ body: (inout SpanHandle<E>) throws(Failure) -> R
    ) throws(Failure) -> R {
        guard isObserved(E.self) else {
            var handle = SpanHandle<E>(stopMetadata: E.initialStopMetadata(), serviceContext: nil)
            return try body(&handle)
        }
        return try _observedSpan(E.self, metadata(), body)
    }

    /// The async form. `isolation` means the body is neither `Sendable` nor
    /// moved to another executor.
    @inlinable
    public static func span<E: SpanEvent, R, Failure: Error>(
        _: E.Type,
        metadata: @autoclosure () -> E.Metadata,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (inout SpanHandle<E>) async throws(Failure) -> R
    ) async throws(Failure) -> R {
        guard isObserved(E.self) else {
            var handle = SpanHandle<E>(stopMetadata: E.initialStopMetadata(), serviceContext: nil)
            return try await body(&handle)
        }
        return try await _observedSpan(E.self, metadata(), isolation: isolation, body)
    }

    @usableFromInline
    static func _observedSpan<E: SpanEvent, R, Failure: Error>(
        _: E.Type, _ metadata: E.Metadata,
        _ body: (inout SpanHandle<E>) throws(Failure) -> R
    ) throws(Failure) -> R {
        var run = SpanRunState<E>(metadata: metadata)
        let outcome: Result<R, Failure> = ServiceContext.withValue(run.context) {
            run.emitStart()
            var handle = SpanHandle<E>(
                stopMetadata: E.initialStopMetadata(), serviceContext: run.context)
            let result: Result<R, Failure>
            do throws(Failure) {
                result = .success(try body(&handle))
            } catch {
                result = .failure(error)
            }
            run.finish(handle.stopMetadata, error: result.error)
            return result
        }
        return try outcome.get()
    }

    @usableFromInline
    static func _observedSpan<E: SpanEvent, R, Failure: Error>(
        _: E.Type, _ metadata: E.Metadata,
        isolation: isolated (any Actor)?,
        _ body: (inout SpanHandle<E>) async throws(Failure) -> R
    ) async throws(Failure) -> R {
        var run = SpanRunState<E>(metadata: metadata)
        let outcome: Result<R, Failure> = await ServiceContext.withValue(run.context) {
            run.emitStart()
            var handle = SpanHandle<E>(
                stopMetadata: E.initialStopMetadata(), serviceContext: run.context)
            let result: Result<R, Failure>
            do throws(Failure) {
                result = .success(try await body(&handle))
            } catch {
                result = .failure(error)
            }
            run.finish(handle.stopMetadata, error: result.error)
            return result
        }
        return try outcome.get()
    }
}

extension Result {
    @usableFromInline var error: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

/// One observed span in flight: its id, its context, the observers running
/// it, and when it started.
@usableFromInline
struct SpanRunState<E: SpanEvent> {
    let metadata: E.Metadata
    @usableFromInline var context: ServiceContext
    let spanID: TelemetrySpanID
    let parentSpanID: TelemetrySpanID?
    var runs: [any SpanRun] = []
    var started: ContinuousClock.Instant = .now

    @usableFromInline
    init(metadata: E.Metadata) {
        self.metadata = metadata
        let parent = ServiceContext.current ?? .topLevel
        let spanID = TelemetrySpanID.generate()
        self.spanID = spanID
        self.parentSpanID = parent.telemetrySpan?.spanID
        var context = parent
        context.telemetrySpan = TelemetrySpanContext(spanID: spanID, parentSpanID: parentSpanID)
        self.context = context

        // Observers see the span first, and may add to the context the body
        // runs under — a tracing span becoming the parent of inner ones.
        if Registry.observersActive.load(ordering: .relaxed) {
            let observers = E.Start._slot.observers(for: E.name)
            if !observers.isEmpty {
                withUnsafePointer(to: metadata) { pointer in
                    let span = SpanStart(
                        name: E.name, kind: E.kind, spanID: spanID, parentSpanID: parentSpanID,
                        metadata: FieldsPointer(pointer: pointer))
                    asHandler {
                        for entry in observers {
                            entry.invoke { body in runs.append(body.observer.start(span, &context))
                            }
                        }
                    }
                }
                self.context = context
            }
        }
    }

    @usableFromInline
    mutating func emitStart() {
        started = .now
        let metadata = self.metadata
        let offset = started - SpanStartMeasurements.reference
        Telemetry.emit(E.Start.self) {
            (SpanStartMeasurements(monotonicTime: offset), metadata)
        }
    }

    @usableFromInline
    func finish(_ stop: E.StopMetadata, error: (any Error)?) {
        let duration = ContinuousClock.now - started
        if let error {
            let failure = E.exceptionMetadata(
                metadata, stop, errorType: String(reflecting: type(of: error)))
            Telemetry.emit(E.Exception.self) {
                (SpanDurationMeasurements(duration: duration), failure)
            }
            guard !runs.isEmpty else { return }
            withUnsafePointer(to: failure) { pointer in
                let span = SpanFailure(
                    name: E.name, spanID: spanID, duration: duration, error: error,
                    metadata: FieldsPointer(pointer: pointer))
                asHandler { for run in runs { run.exception(span) } }
            }
        } else {
            let stopped = E.stopMetadata(metadata, stop)
            Telemetry.emit(E.Stop.self) { (SpanDurationMeasurements(duration: duration), stopped) }
            guard !runs.isEmpty else { return }
            withUnsafePointer(to: stopped) { pointer in
                let span = SpanStop(
                    name: E.name, spanID: spanID, duration: duration,
                    metadata: FieldsPointer(pointer: pointer))
                asHandler { for run in runs { run.stop(span) } }
            }
        }
    }
}

/// Runs observer callbacks as handlers: counted in the dispatch depth, so a
/// detach from inside one does not wait (see ``HandlerSlot``).
private func asHandler(_ body: () -> Void) {
    let thread = DispatchThread.current
    thread.pointee.depth += 1
    defer { thread.pointee.depth -= 1 }
    body()
}
