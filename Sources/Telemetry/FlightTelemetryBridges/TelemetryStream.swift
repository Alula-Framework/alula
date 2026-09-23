import FlightTelemetry
import Synchronization

/// Events handed to async code through a bounded buffer — for an exporter
/// whose work is too slow for a handler, which runs on the emitting thread.
///
/// ```swift
/// let failures = try Telemetry.stream(SessionEvents.StoreFailed.self, id: "pager", capacity: 256)
/// for await failure in failures.events {
///     await pager.notify("session store \(failure.metadata.operation) failed")
/// }
/// ```
///
/// The handler copies the event and yields it; nothing else runs on the
/// emitter. The buffer is bounded — `capacity` events, and past that the
/// oldest (or the newest) are dropped and counted in ``droppedCount`` —
/// so a consumer falling behind costs memory up to a fixed amount and
/// never slows the application down. Dropping the subscription detaches
/// the handler and finishes the stream.
public struct TelemetrySubscription<Element: Sendable>: ~Copyable {
    /// The events, in emit order per emitting thread.
    public let events: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation
    private let dropped: DropCount
    private let token: HandlerToken

    /// Events the buffer was full for, so far.
    public var droppedCount: Int { dropped.value.load(ordering: .relaxed) }

    init(
        events: AsyncStream<Element>, continuation: AsyncStream<Element>.Continuation,
        dropped: DropCount, token: consuming HandlerToken
    ) {
        self.events = events
        self.continuation = continuation
        self.dropped = dropped
        self.token = token
    }

    deinit {
        continuation.finish()
    }
}

/// What a full buffer gives up.
public enum TelemetryStreamOverflow: Sendable {
    /// Keep the newest `capacity` events: a consumer catching up sees the
    /// present. The right default for monitoring.
    case dropOldest
    /// Keep the first `capacity` events and refuse later ones.
    case dropNewest
}

final class DropCount: Sendable {
    let value = Atomic<Int>(0)
}

extension Telemetry {
    /// Every emit of `E`, through a bounded buffer to async code.
    public static func stream<E: TelemetryEvent>(
        _: E.Type, id: HandlerID, capacity: Int, overflow: TelemetryStreamOverflow = .dropOldest
    ) throws(AttachError) -> TelemetrySubscription<EventRecord<E>> {
        let (events, continuation, dropped) = buffer(EventRecord<E>.self, capacity, overflow)
        let token = try attach(E.self, id: id) { measurements, metadata, context in
            if case .dropped = continuation.yield(EventRecord(measurements, metadata, context)) {
                dropped.value.add(1, ordering: .relaxed)
            }
        }
        return TelemetrySubscription(
            events: events, continuation: continuation, dropped: dropped, token: token)
    }

    /// Every event under `prefix`, through a bounded buffer to async code.
    public static func stream(
        prefix: EventName, id: HandlerID, capacity: Int,
        overflow: TelemetryStreamOverflow = .dropOldest
    ) throws(AttachError) -> TelemetrySubscription<AnyEventRecord> {
        let (events, continuation, dropped) = buffer(AnyEventRecord.self, capacity, overflow)
        let token = try attach(prefix: prefix, id: id) { event in
            if case .dropped = continuation.yield(AnyEventRecord(event)) {
                dropped.value.add(1, ordering: .relaxed)
            }
        }
        return TelemetrySubscription(
            events: events, continuation: continuation, dropped: dropped, token: token)
    }

    private static func buffer<Element: Sendable>(
        _: Element.Type, _ capacity: Int, _ overflow: TelemetryStreamOverflow
    ) -> (AsyncStream<Element>, AsyncStream<Element>.Continuation, DropCount) {
        precondition(capacity > 0, "a telemetry stream needs room for at least one event")
        let policy: AsyncStream<Element>.Continuation.BufferingPolicy =
            switch overflow {
            case .dropOldest: .bufferingNewest(capacity)
            case .dropNewest: .bufferingOldest(capacity)
            }
        let (events, continuation) = AsyncStream.makeStream(
            of: Element.self, bufferingPolicy: policy)
        return (events, continuation, DropCount())
    }
}
