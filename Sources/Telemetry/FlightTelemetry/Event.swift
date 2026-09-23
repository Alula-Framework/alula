import ServiceContextModule
import Synchronization

/// Something that happened, as a library states it — with the numbers a
/// metric aggregates and the dimensions it is sliced by.
///
/// A caseless enum, so the type is a name and nothing more:
///
/// ```swift
/// @TelemetryEvent("flight.sessions.created")
/// public enum SessionCreated {}
///
/// @TelemetryEvent("hangar.query")
/// public enum Query {
///     public struct Measurements { public var duration: Duration; public var rows: Int }
///     public struct Metadata { public var table: String }
/// }
/// ```
///
/// The macro writes the conformance; every piece of it can be written by
/// hand. What a library never does is decide what an event becomes — a
/// counter, a span, a log line, or nothing. The application does, by
/// attaching handlers, and until it does an emit costs a load and a branch.
public protocol TelemetryEvent: Sendable {
    associatedtype Measurements: TelemetryFields = NoFields
    associatedtype Metadata: TelemetryFields = NoFields

    static var name: EventName { get }

    /// This event type's handlers. One per type, stored statically, so the
    /// emit path finds its handlers without a dictionary lookup. The macro
    /// writes `static let _slot = HandlerSlot<Self>()`.
    static var _slot: HandlerSlot<Self> { get }
}

/// Identifies a telemetry span within the process, for correlating an
/// event with the span it happened inside.
public struct TelemetrySpanID: Sendable, Hashable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public var description: String { String(rawValue, radix: 16) }

    static let next = Atomic<UInt64>(1)
    static func generate() -> TelemetrySpanID {
        TelemetrySpanID(rawValue: next.wrappingAdd(1, ordering: .relaxed).oldValue)
    }
}

/// The span a `ServiceContext` is inside, and the one that one is inside.
public struct TelemetrySpanContext: Sendable, Hashable {
    public let spanID: TelemetrySpanID
    public let parentSpanID: TelemetrySpanID?
}

/// Where a ``TelemetrySpanContext`` travels on a `ServiceContext`, so it
/// follows structured concurrency without any telemetry-specific plumbing.
public enum TelemetrySpanContextKey: ServiceContextKey {
    public typealias Value = TelemetrySpanContext
    public static var nameOverride: String? { "flight.telemetry.span" }
}

extension ServiceContext {
    /// The telemetry span this context is inside, if any.
    public var telemetrySpan: TelemetrySpanContext? {
        get { self[TelemetrySpanContextKey.self] }
        set { self[TelemetrySpanContextKey.self] = newValue }
    }
}

/// What every handler is told besides the payload: when, and inside what.
///
/// A view into the dispatch, like ``AnyEvent``: noncopyable and handed to
/// handlers `borrowing`, so it cannot outlive the emit it describes. Each
/// value is read on first access — at most once per emit, then shared by
/// every handler — which is why an emit whose handlers never ask pays for
/// neither the clock nor the task-local read. A metrics reporter never
/// asks. To keep the values, take a ``snapshot()``.
public struct EventContext: ~Copyable {
    @usableFromInline let frame: UnsafeMutablePointer<Frame>

    @usableFromInline
    init(frame: UnsafeMutablePointer<Frame>) {
        self.frame = frame
    }

    /// When the event was emitted — read by the first handler to ask, and
    /// the same for every handler after it.
    public var timestamp: ContinuousClock.Instant {
        if let timestamp = frame.pointee.timestamp { return timestamp }
        let now = ContinuousClock.now
        frame.pointee.timestamp = now
        return now
    }

    /// `ServiceContext.current` where the event was emitted — trace ids and
    /// the like.
    public var serviceContext: ServiceContext? {
        if let read = frame.pointee.serviceContext { return read }
        let current = ServiceContext.current
        frame.pointee.serviceContext = .some(current)
        return current
    }

    /// The telemetry span the event was emitted inside.
    public var spanID: TelemetrySpanID? { serviceContext?.telemetrySpan?.spanID }

    /// The values, as a copy that can be kept.
    public func snapshot() -> Snapshot {
        Snapshot(timestamp: timestamp, serviceContext: serviceContext)
    }

    /// An ``EventContext``'s values, kept.
    public struct Snapshot: Sendable {
        public let timestamp: ContinuousClock.Instant
        public let serviceContext: ServiceContext?
        public var spanID: TelemetrySpanID? { serviceContext?.telemetrySpan?.spanID }

        public init(timestamp: ContinuousClock.Instant, serviceContext: ServiceContext?) {
            self.timestamp = timestamp
            self.serviceContext = serviceContext
        }
    }

    /// Where a dispatch keeps what its context has read so far.
    @usableFromInline
    struct Frame {
        @usableFromInline var timestamp: ContinuousClock.Instant?
        /// `.none` until read; `.some(nil)` when read and there was none.
        @usableFromInline var serviceContext: ServiceContext??

        @inlinable init() {}
    }
}

/// A handler's identity for one event type or prefix — what makes attaching
/// the same handler twice an error rather than a double count.
public struct HandlerID: Sendable, Hashable, CustomStringConvertible,
    ExpressibleByStringInterpolation
{
    public let description: String
    public init(_ value: String) { self.description = value }
    public init(stringLiteral value: String) { self.init(value) }
}

/// Why an attach was refused.
public enum AttachError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A handler with this id is already attached to this event type or
    /// prefix — `:telemetry`'s `{:error, :already_exists}`.
    case duplicateID(HandlerID, EventName)
    /// Another event type already owns this one's name. An event name is an
    /// external identity — dashboards, alerts and log queries key on it —
    /// so two schemas cannot share one; rename one of the types.
    case nameConflict(EventName, owner: String)

    public var description: String {
        switch self {
        case .duplicateID(let id, let name):
            "a telemetry handler '\(id)' is already attached to \(name)"
        case .nameConflict(let name, let owner):
            "\(name) is already the name of \(owner); two event types cannot share one name"
        }
    }
}

/// A typed handler: the payload by type, no boxing, no dictionary.
///
/// Handlers run synchronously on the emitting thread, may be called
/// concurrently, and must not block or take a lock an emitter might hold.
/// Throwing detaches the handler — see ``TelemetryHandlerFailed``.
public typealias TelemetryHandler<E: TelemetryEvent> =
    @Sendable (borrowing E.Measurements, borrowing E.Metadata, borrowing EventContext) throws ->
    Void
