import FlightTelemetry
import Synchronization

/// Captures the events a piece of code emits — only that code's, even with
/// every other test in the process emitting the same events at once.
///
/// ```swift
/// @Test func queryEmitsStop() async throws {
///     let stops = try await TelemetryTest.capture(HangarQuery.Stop.self) {
///         try await repository.all(User.self)
///     }
///     #expect(stops.count == 1)
///     #expect(stops[0].metadata.table == "users")
/// }
/// ```
///
/// A capture binds a scope in a task-local for the length of its body; one
/// shared handler per event type records an emit only for the scopes that
/// are current where it happens. Child tasks inherit the scope, so their
/// events are captured; parallel tests have different scopes, so theirs are
/// not. Production code pays nothing for any of this — the task-local is
/// read only by handlers that exist only during a capture.
///
/// Not captured: work that leaves structured concurrency — `Task.detached`,
/// or a thread Swift concurrency doesn't manage, such as a NIO event loop
/// that does not carry the task-local across.
public enum TelemetryTest {
    /// The captures enclosing the current task, innermost last.
    @TaskLocal static var scopes: [UInt64] = []

    // MARK: Typed

    /// Every emit of `E` inside `body`.
    public static func capture<E: TelemetryEvent, Failure: Error>(
        _: E.Type,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws(Failure) -> Void
    ) async throws(Failure) -> [CapturedEvent<E>] {
        let sink = Sink<CapturedEvent<E>>()
        let attachment = Shared.typed(E.self)
        defer { Shared.release(attachment) }
        try await within(sink, isolation: isolation, body)
        return sink.items
    }

    /// Every emit of `E` inside `body`, for synchronous code.
    public static func capture<E: TelemetryEvent, Failure: Error>(
        _: E.Type, _ body: () throws(Failure) -> Void
    ) throws(Failure) -> [CapturedEvent<E>] {
        let sink = Sink<CapturedEvent<E>>()
        let attachment = Shared.typed(E.self)
        defer { Shared.release(attachment) }
        try within(sink, body)
        return sink.items
    }

    // MARK: Erased

    /// Every event under `prefix` emitted inside `body`, in order, whatever
    /// its type.
    public static func capture<Failure: Error>(
        prefix: EventName,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws(Failure) -> Void
    ) async throws(Failure) -> [CapturedAnyEvent] {
        let sink = Sink<CapturedAnyEvent>(prefix: prefix)
        let attachment = Shared.erased(prefix)
        defer { Shared.release(attachment) }
        try await within(sink, isolation: isolation, body)
        return sink.items
    }

    /// Every event under `prefix` emitted inside `body`, for synchronous code.
    public static func capture<Failure: Error>(
        prefix: EventName, _ body: () throws(Failure) -> Void
    ) throws(Failure) -> [CapturedAnyEvent] {
        let sink = Sink<CapturedAnyEvent>(prefix: prefix)
        let attachment = Shared.erased(prefix)
        defer { Shared.release(attachment) }
        try within(sink, body)
        return sink.items
    }

    /// Throws ``UnexpectedEmission`` if anything under `prefix` is emitted
    /// inside `body` — a thrown error fails the test under any framework.
    public static func expectNoEmission(
        prefix: EventName,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> Void
    ) async throws {
        let events = try await capture(prefix: prefix, isolation: isolation, body)
        if !events.isEmpty { throw UnexpectedEmission(events: events) }
    }

    /// Throws ``UnexpectedEmission`` if anything under `prefix` is emitted
    /// inside `body`, for synchronous code.
    public static func expectNoEmission(prefix: EventName, _ body: () throws -> Void) throws {
        let events = try capture(prefix: prefix, body)
        if !events.isEmpty { throw UnexpectedEmission(events: events) }
    }

    // MARK: Spans

    /// Every phase of every `S` span inside `body`.
    public static func captureSpans<S: SpanEvent, Failure: Error>(
        _: S.Type,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws(Failure) -> Void
    ) async throws(Failure) -> CapturedSpans<S> {
        let starts = Sink<CapturedEvent<S.Start>>()
        let stops = Sink<CapturedEvent<S.Stop>>()
        let exceptions = Sink<CapturedEvent<S.Exception>>()
        let attachments = [
            Shared.typed(S.Start.self), Shared.typed(S.Stop.self), Shared.typed(S.Exception.self),
        ]
        defer { attachments.forEach(Shared.release) }
        let scope = Scopes.open([starts, stops, exceptions])
        defer { Scopes.close(scope) }
        try await $scopes.withValue(scopes + [scope], operation: body, isolation: isolation)
        return CapturedSpans(starts: starts.items, stops: stops.items, exceptions: exceptions.items)
    }

    /// Every phase of every `S` span inside `body`, for synchronous code.
    public static func captureSpans<S: SpanEvent, Failure: Error>(
        _: S.Type, _ body: () throws(Failure) -> Void
    ) throws(Failure) -> CapturedSpans<S> {
        let starts = Sink<CapturedEvent<S.Start>>()
        let stops = Sink<CapturedEvent<S.Stop>>()
        let exceptions = Sink<CapturedEvent<S.Exception>>()
        let attachments = [
            Shared.typed(S.Start.self), Shared.typed(S.Stop.self), Shared.typed(S.Exception.self),
        ]
        defer { attachments.forEach(Shared.release) }
        let scope = Scopes.open([starts, stops, exceptions])
        defer { Scopes.close(scope) }
        try withScopes(scopes + [scope], body)
        return CapturedSpans(starts: starts.items, stops: stops.items, exceptions: exceptions.items)
    }

    // MARK: Scoping

    private static func within<Failure: Error>(
        _ sink: some AnySink,
        isolation: isolated (any Actor)?,
        _ body: () async throws(Failure) -> Void
    ) async throws(Failure) {
        let scope = Scopes.open([sink])
        defer { Scopes.close(scope) }
        try await $scopes.withValue(scopes + [scope], operation: body, isolation: isolation)
    }

    private static func within<Failure: Error>(
        _ sink: some AnySink, _ body: () throws(Failure) -> Void
    ) throws(Failure) {
        let scope = Scopes.open([sink])
        defer { Scopes.close(scope) }
        try withScopes(scopes + [scope], body)
    }

    /// `TaskLocal.withValue`'s synchronous form rethrows untyped; this keeps
    /// the body's error type.
    private static func withScopes<Failure: Error>(
        _ value: [UInt64], _ body: () throws(Failure) -> Void
    ) throws(Failure) {
        let result: Result<Void, Failure> = $scopes.withValue(value) {
            do throws(Failure) {
                try body()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
    }
}

extension TaskLocal {
    /// `withValue` for an async body with a typed error: the standard one
    /// rethrows untyped.
    fileprivate func withValue<Failure: Error>(
        _ value: Value,
        operation: () async throws(Failure) -> Void,
        isolation: isolated (any Actor)?
    ) async throws(Failure) {
        let result: Result<Void, Failure> = await withValue(
            value,
            operation: {
                do throws(Failure) {
                    try await operation()
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }, isolation: isolation)
        try result.get()
    }
}

/// One emit, as a typed handler saw it.
public struct CapturedEvent<E: TelemetryEvent>: Sendable {
    public let measurements: E.Measurements
    public let metadata: E.Metadata
    public let context: EventContext.Snapshot
}

/// One emit, as an erased handler saw it: its name and its fields by name.
public struct CapturedAnyEvent: Sendable, CustomStringConvertible {
    public let name: EventName
    public let context: EventContext.Snapshot
    /// Measurements in declaration order.
    public let measurements: [(name: String, value: any TelemetryMeasurement)]
    /// Metadata in declaration order; absent optionals are not here.
    public let metadata: [(name: String, value: any TelemetryValue)]

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

/// The phases of the spans a capture saw.
public struct CapturedSpans<S: SpanEvent>: Sendable {
    public let starts: [CapturedEvent<S.Start>]
    public let stops: [CapturedEvent<S.Stop>]
    public let exceptions: [CapturedEvent<S.Exception>]
}

/// Thrown by ``TelemetryTest/expectNoEmission(prefix:isolation:_:)`` —
/// its description lists what was emitted.
public struct UnexpectedEmission: Error, CustomStringConvertible {
    public let events: [CapturedAnyEvent]

    public var description: String {
        "expected no telemetry, but \(events.count) event(s) were emitted:\n"
            + events.map { "  \($0)" }.joined(separator: "\n")
    }
}

// MARK: - Plumbing

/// Where a capture's events go.
protocol AnySink: AnyObject, Sendable {
    func offer(_ item: any Sendable)
    /// An event from the shared handler for `prefix`. A sink takes it only
    /// from its own prefix's handler: with captures of `flight` and
    /// `flight.apns` both live, the event reaches both handlers, and each
    /// sink must count it once.
    func offer(erased event: borrowing AnyEvent, from prefix: EventName)
}

final class Sink<Item: Sendable>: AnySink {
    private let collected = Lock<[Item]>([])
    private let prefix: EventName?

    init(prefix: EventName? = nil) {
        self.prefix = prefix
    }

    var items: [Item] { collected.withLock { $0 } }

    func offer(_ item: any Sendable) {
        guard let item = item as? Item else { return }
        collected.withLock { $0.append(item) }
    }

    func offer(erased event: borrowing AnyEvent, from handlerPrefix: EventName) {
        guard let prefix, prefix == handlerPrefix, Item.self == CapturedAnyEvent.self else {
            return
        }
        var measurements: [(name: String, value: any TelemetryMeasurement)] = []
        var metadata: [(name: String, value: any TelemetryValue)] = []
        event.forEachMeasurement { measurements.append(($0, $1)) }
        event.forEachMetadata { metadata.append(($0, $1)) }
        let captured = CapturedAnyEvent(
            name: event.name, context: event.context.snapshot(), measurements: measurements,
            metadata: metadata)
        offer(captured)
    }
}

/// Live captures by scope id.
enum Scopes {
    private static let next = Atomic<UInt64>(1)
    private static let live = Lock<[UInt64: [any AnySink]]>([:])

    static func open(_ sinks: [any AnySink]) -> UInt64 {
        let id = next.wrappingAdd(1, ordering: .relaxed).oldValue
        live.withLock { $0[id] = sinks }
        return id
    }

    static func close(_ id: UInt64) {
        live.withLock { $0[id] = nil }
    }

    /// The sinks of the captures current where this runs.
    static func current() -> [any AnySink] {
        let scopes = TelemetryTest.scopes
        guard !scopes.isEmpty else { return [] }
        return live.withLock { live in scopes.flatMap { live[$0] ?? [] } }
    }
}

/// One capturing handler per event type or prefix, shared by every
/// concurrent capture of it and detached when the last one ends.
enum Shared {
    private final class Attachment: Sendable {
        let token: Lock<HandlerToken?>
        let count = Atomic<Int>(1)
        init(_ token: consuming HandlerToken) { self.token = Lock(token) }
    }

    private static let attachments = Lock<[String: Attachment]>([:])
    private static let id: HandlerID = "flight.telemetry.testing"

    static func typed<E: TelemetryEvent>(_: E.Type) -> String {
        retain("type:\(E.name)") { () throws(AttachError) in
            try Telemetry.attach(E.self, id: id) { measurements, metadata, context in
                let sinks = Scopes.current()
                guard !sinks.isEmpty else { return }
                let captured = CapturedEvent<E>(
                    measurements: copy measurements, metadata: copy metadata,
                    context: context.snapshot())
                for sink in sinks { sink.offer(captured) }
            }
        }
    }

    static func erased(_ prefix: EventName) -> String {
        retain("prefix:\(prefix)") { () throws(AttachError) in
            try Telemetry.attach(prefix: prefix, id: id) { event in
                for sink in Scopes.current() { sink.offer(erased: event, from: prefix) }
            }
        }
    }

    private static func retain(
        _ key: String, _ attach: () throws(AttachError) -> HandlerToken
    ) -> String {
        attachments.withLock { attachments in
            if let existing = attachments[key] {
                existing.count.add(1, ordering: .relaxed)
            } else {
                do {
                    attachments[key] = Attachment(try attach())
                } catch {
                    // Only this module attaches with this id, under this lock.
                    preconditionFailure(
                        "FlightTelemetryTesting could not attach its handler: \(error)")
                }
            }
        }
        return key
    }

    static func release(_ key: String) {
        attachments.withLock { attachments in
            guard let attachment = attachments[key] else { return }
            if attachment.count.subtract(1, ordering: .relaxed).newValue == 0 {
                attachments[key] = nil
                attachment.token.withLock { token in
                    if let token = token.take() { token.detach() }
                }
            }
        }
    }
}

extension Optional where Wrapped: ~Copyable {
    fileprivate mutating func take() -> Wrapped? {
        switch consume self {
        case .some(let value):
            self = nil
            return value
        case .none:
            self = nil
            return nil
        }
    }
}
