import ServiceContextModule
import Synchronization

/// Emitting events and attaching handlers.
///
/// ```swift
/// Telemetry.emit(SessionCreated.self)
/// Telemetry.emit(Query.self) { (.init(duration: elapsed, rows: rows.count), .init(table: "users")) }
/// ```
///
/// With nothing attached an emit is a relaxed atomic load or two and a
/// branch: no allocation, no lock, no task-local read, and the payload
/// closure never runs. Everything else is paid only by an event someone is
/// listening to.
public enum Telemetry {

    // MARK: Emitting

    /// Emits `E`, building its payload only if a handler will see it.
    @inlinable
    public static func emit<E: TelemetryEvent>(
        _: E.Type, _ payload: () -> (E.Measurements, E.Metadata)
    ) {
        guard isEnabled(E.self) else { return }
        let (measurements, metadata) = payload()
        _dispatch(E.self, measurements, metadata)
    }

    /// Emits an event with no measurements and no metadata.
    @inlinable
    public static func emit<E: TelemetryEvent>(_: E.Type)
    where E.Measurements == NoFields, E.Metadata == NoFields {
        guard isEnabled(E.self) else { return }
        _dispatch(E.self, NoFields(), NoFields())
    }

    /// Emits an event whose measurements are empty.
    @inlinable
    public static func emit<E: TelemetryEvent>(_: E.Type, metadata: () -> E.Metadata)
    where E.Measurements == NoFields {
        guard isEnabled(E.self) else { return }
        _dispatch(E.self, NoFields(), metadata())
    }

    /// Emits an event whose metadata is empty.
    @inlinable
    public static func emit<E: TelemetryEvent>(_: E.Type, measurements: () -> E.Measurements)
    where E.Metadata == NoFields {
        guard isEnabled(E.self) else { return }
        _dispatch(E.self, measurements(), NoFields())
    }

    /// Whether anything would see an emit of `E`. For the one case the
    /// payload closure cannot cover: collecting a measurement *before* the
    /// emit point, such as reading a clock at the start of an operation.
    @inlinable
    public static func isEnabled<E: TelemetryEvent>(_: E.Type) -> Bool {
        E._slot.flags.load(ordering: .relaxed) & (SlotFlags.typed | SlotFlags.erased) != 0
    }

    /// The slow path: somebody is listening.
    ///
    /// Inlined into the emit site, so the typed handlers are called with the
    /// payload's concrete types — specialized, with no generic copies — and
    /// only the rare branches (first emit of a type, the depth cap, a stale
    /// erased cache, a handler throwing) leave it.
    @inlinable
    static func _dispatch<E: TelemetryEvent>(
        _: E.Type, _ measurements: E.Measurements, _ metadata: E.Metadata
    ) {
        let slot = E._slot
        if !slot.registered.load(ordering: .relaxed) { _register(E.self) }
        let thread = DispatchThread.current
        guard thread.pointee.depth < DispatchThread.limit else {
            _depthExceeded(E.self)
            return
        }
        if !slot.erasedCurrent, thread.pointee.depth == 0 { slot.refreshErased() }

        thread.pointee.depth += 1
        let (parity, published) = slot.enterRead()
        defer {
            slot.exitRead(parity)
            thread.pointee.depth -= 1
        }
        guard let published else { return }
        var frame = EventContext.Frame()
        withUnsafeMutablePointer(to: &frame) { frame in
            Unmanaged<_Handlers<E>>.fromOpaque(published)._withUnsafeGuaranteedRef { handlers in
                let context = EventContext(frame: frame)
                for index in handlers.bodies.indices {
                    do {
                        try handlers.bodies[index](measurements, metadata, context)
                    } catch {
                        _handlerFailed(E.self, handlers.ids[index], error)
                    }
                }
                guard !handlers.erased.isEmpty else { return }
                withUnsafePointer(to: measurements) { measurements in
                    withUnsafePointer(to: metadata) { metadata in
                        _dispatchErased(
                            AnyEvent(
                                context: context,
                                payload: TypedPayload<E>(
                                    measurements: measurements, metadata: metadata)),
                            handlers.erased)
                    }
                }
            }
        }
    }

    /// Checks `E`'s name against every other type's, once.
    @usableFromInline @inline(never)
    static func _register<E: TelemetryEvent>(_: E.Type) {
        Registry.register(E.name, E.self)
        E._slot.registered.store(true, ordering: .relaxed)
    }

    /// A handler emitting, whose handler emits, and so on: past the cap the
    /// nested emit is dropped rather than recursing forever.
    @usableFromInline @inline(never)
    static func _depthExceeded<E: TelemetryEvent>(_: E.Type) {
        if !E._slot.warnedDepth.exchange(true, ordering: .relaxed) {
            TelemetryDiagnostics.warn(
                "dispatch of \(E.name) re-entered more than \(DispatchThread.limit) levels deep; nested emits are dropped"
            )
        }
    }

    @usableFromInline @inline(never)
    static func _handlerFailed<E: TelemetryEvent>(_: E.Type, _ id: HandlerID, _ error: any Error) {
        E._slot.detach(id)
        reportFailure(event: E.name, handler: id, error: error)
    }

    @usableFromInline @inline(never)
    static func _dispatchErased(
        _ event: borrowing AnyEvent, _ entries: ContiguousArray<ErasedEntry>
    ) {
        // Already matched by prefix: the list was built from those that do.
        for entry in entries {
            do {
                try entry.invoke(event)
            } catch {
                Registry.detachErased(entry)
                reportFailure(event: event.name, handler: entry.id, error: error)
            }
        }
    }

    static func reportFailure(event: EventName, handler: HandlerID, error: any Error) {
        emit(TelemetryHandlerFailed.self) {
            (
                NoFields(),
                TelemetryHandlerFailed.Metadata(
                    event: event.description, handler: handler.description,
                    errorType: String(reflecting: type(of: error)))
            )
        }
    }

    // MARK: Attaching

    /// Attaches `handler` to every emit of `E` until the token is released.
    ///
    /// - Throws: ``AttachError/duplicateID(_:_:)`` when `id` is already
    ///   attached to `E`.
    public static func attach<E: TelemetryEvent>(
        _: E.Type, id: HandlerID, _ handler: @escaping TelemetryHandler<E>
    ) throws(AttachError) -> HandlerToken {
        _register(E.self)
        try E._slot.attach(_TypedHandler(id: id, body: handler))
        return HandlerToken { E._slot.detach(id) }
    }

    /// Attaches `handler` to every event whose name lies under `prefix`,
    /// seen through ``AnyEvent``.
    ///
    /// For logging bridges and debugging: this path pays for existentials
    /// when it reads fields, which a typed handler does not.
    public static func attach(
        prefix: EventName, id: HandlerID,
        _ handler: @escaping @Sendable (borrowing AnyEvent) throws -> Void
    ) throws(AttachError) -> HandlerToken {
        let entry = ErasedEntry(id: id, prefix: prefix, handler: handler)
        try Registry.attachErased(entry)
        return HandlerToken { Registry.detachErased(entry) }
    }
}

/// An attachment, alive for as long as this value is.
///
/// Noncopyable, and detaching when destroyed: a test, or a short-lived
/// service, cannot leak a handler by forgetting it. An application attaches
/// for its whole life by keeping the token — `FlightTelemetryModule` does —
/// or by calling ``persist()``.
public struct HandlerToken: ~Copyable, Sendable {
    private let detachAction: @Sendable () -> Void
    private var armed = true

    init(_ detach: @escaping @Sendable () -> Void) {
        self.detachAction = detach
    }

    /// Detaches now. When this returns the handler will not be called again,
    /// even by an emit already in progress on another thread.
    public consuming func detach() {}

    /// Keeps the handler attached for the life of the process.
    public consuming func persist() {
        armed = false
    }

    deinit {
        if armed { detachAction() }
    }
}

/// Several tokens held as one — what a reporter or a module keeps.
public struct HandlerTokens: ~Copyable, Sendable {
    private var tokens: [DetachBox] = []

    public init() {}

    /// Adds a token; it detaches when this collection does.
    public mutating func append(_ token: consuming HandlerToken) {
        tokens.append(DetachBox(token))
    }

    /// Takes over another collection's tokens.
    public mutating func append(contentsOf other: consuming HandlerTokens) {
        tokens.append(contentsOf: other.tokens)
    }

    public var count: Int { tokens.count }

    /// Detaches everything now.
    public consuming func detach() {}

    /// Keeps everything attached for the life of the process.
    public consuming func persist() {
        for box in tokens { box.persist() }
    }
}

/// A token in a reference, so a collection of them can be an array.
private final class DetachBox: Sendable {
    private let token: Lock<HandlerToken?>

    init(_ token: consuming HandlerToken) {
        self.token = Lock(token)
    }

    func persist() {
        token.withLock { slot in slot.take()?.persist() }
    }

    deinit {
        token.withLock { slot in slot.take()?.detach() }
    }
}

/// Emitted when a handler throws. The handler is detached first — a handler
/// that fails once fails again, and an emitter should not pay for that on
/// every event — and every other handler for the event still runs.
public enum TelemetryHandlerFailed: TelemetryEvent {
    public struct Metadata: TelemetryFields {
        /// The event whose handler failed.
        public var event: String
        public var handler: String
        public var errorType: String

        public func encode(into encoder: inout FieldEncoder) {
            encoder.value("event", event)
            encoder.value("handler", handler)
            encoder.value("error_type", errorType)
        }

        public static func fieldName(for keyPath: PartialKeyPath<Metadata>) -> String? {
            switch keyPath {
            case \Metadata.event: "event"
            case \Metadata.handler: "handler"
            case \Metadata.errorType: "error_type"
            default: nil
            }
        }
    }

    public static let name: EventName = "flight.telemetry.handler_failed"
    public static let _slot = HandlerSlot<TelemetryHandlerFailed>()
}

extension Optional where Wrapped: ~Copyable {
    /// Moves the value out, leaving `nil`.
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
