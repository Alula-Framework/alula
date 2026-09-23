import Synchronization

/// Per event type: its typed handlers, published for lock-free reading, and
/// a cache of the erased handlers and span observers whose prefixes match.
///
/// **Reading.** An emit reads the current handler list without a lock: it
/// announces itself in one of two reader counters, loads the list, calls the
/// handlers, and leaves. One atomic increment and one decrement per emit,
/// however many handlers — no mutex, and no per-handler bookkeeping.
///
/// **Writing.** Attaching or detaching builds a new list and swaps it in.
/// The old list may still be in a reader's hands, so it is freed only after
/// a *grace period*: the epoch is flipped twice and each reader counter
/// waited to zero, after which no emit can still hold anything published
/// before the swap. That wait is also the detach guarantee — once `detach`
/// returns, no emit anywhere still has a list containing the handler.
///
/// A detach from *inside* a handler does not wait: this thread is itself a
/// reader, and two threads each detaching the other's handler would wait on
/// each other forever. It takes effect for every emit that starts after it,
/// and the old list is freed when the outermost emit on that thread ends.
public final class HandlerSlot<E: TelemetryEvent>: Sendable, EnrolledSlot, DeferredReclaim {
    /// The whole fast path, in one load: whether typed handlers exist, and
    /// whether an erased handler's prefix matches this event — the registry
    /// sets that bit only on slots a prefix matches, so an emit never reads
    /// a global and a narrow prefix costs other events nothing. See
    /// ``SlotFlags``.
    @usableFromInline let flags = Atomic<UInt8>(0)

    /// The published list: an `Unmanaged<_Handlers<E>>`, retained once, by
    /// bit pattern — zero for none. (A pointer is not `Sendable`; its bits
    /// are, and the grace period is what makes sharing them sound.)
    @usableFromInline let current = Atomic<UInt>(0)
    /// Which reader counter a new emit announces itself in.
    @usableFromInline let epoch = Atomic<Int>(0)
    @usableFromInline let readersEven = Atomic<Int>(0)
    @usableFromInline let readersOdd = Atomic<Int>(0)
    /// The erased-registry generation `current` was built against.
    @usableFromInline let erasedGeneration = Atomic<UInt64>(0)

    struct Writer {
        var typed: [_TypedHandler<E>] = []
        /// Lists swapped out and not yet freed, by bit pattern.
        var retired: [UInt] = []
    }
    let writer = Lock(Writer())
    /// Serializes grace periods, whose two epoch flips must not interleave;
    /// counts those completed. (Not `Lock(())`: a zero-sized state shares
    /// its address with the lock's own storage, and ThreadSanitizer reports
    /// the overlap as a race.)
    let grace = Lock(0)
    let observerCache = Lock<(generation: UInt64, entries: [ObserverEntry])>((UInt64.max, []))

    /// Set when another type already owned this type's name at creation:
    /// nothing may attach, and the flags stay clear so every emit is dropped.
    let disowned: (owner: String, name: EventName)?
    /// Whether a depth-cap drop has been reported for this type.
    let warnedDepth = Atomic<Bool>(false)

    /// The span this slot is a phase of, and its bit there.
    let span: (flags: SpanFlags, bit: UInt8)?

    public init() {
        self.span = nil
        self.disowned = Self.claim()
        Registry.enroll(self)
    }

    /// A span phase's slot: attaching to it also marks the span observed,
    /// so running the span checks one word, not three slots.
    public init(span: SpanFlags, phase: SpanPhase) {
        self.span = (span, phase.bit)
        self.disowned = Self.claim()
        Registry.enroll(self)
    }

    private static func claim() -> (owner: String, name: EventName)? {
        let claim = Registry.register(E.name, E.self)
        return claim.owns ? nil : (claim.owner, E.name)
    }

    var eventNames: [EventName] { [E.name] }
    var spanName: EventName? { nil }

    func setGlobal(_ bit: UInt8, _ on: Bool) {
        guard disowned == nil else { return }
        if on {
            flags.bitwiseOr(bit, ordering: .relaxed)
        } else {
            flags.bitwiseAnd(~bit, ordering: .relaxed)
        }
    }

    deinit {
        // Slots are static; this runs only if one is not — a test's, say.
        Self.release(current.load(ordering: .relaxed))
        writer.withLock { $0.retired.forEach(Self.release) }
    }

    // MARK: Reading

    /// Enters a read: the counter to leave by, and the list, if any.
    @inlinable @inline(__always)
    func enterRead() -> (parity: Int, list: UnsafeMutableRawPointer?) {
        let parity = epoch.load(ordering: .relaxed) & 1
        if parity == 0 {
            readersEven.add(1, ordering: .sequentiallyConsistent)
        } else {
            readersOdd.add(1, ordering: .sequentiallyConsistent)
        }
        return (
            parity,
            UnsafeMutableRawPointer(bitPattern: current.load(ordering: .sequentiallyConsistent))
        )
    }

    @inlinable @inline(__always)
    func exitRead(_ parity: Int) {
        if parity == 0 {
            readersEven.subtract(1, ordering: .releasing)
        } else {
            readersOdd.subtract(1, ordering: .releasing)
        }
    }

    /// Whether the published list reflects the erased registry — the one
    /// thing that can change it without an attach or detach on this type.
    @inlinable @inline(__always)
    var erasedCurrent: Bool {
        erasedGeneration.load(ordering: .relaxed)
            == Registry.erasedGeneration.load(ordering: .relaxed)
    }

    // MARK: Writing

    func attach(_ handler: _TypedHandler<E>) throws(AttachError) {
        if let disowned { throw .nameConflict(disowned.name, owner: disowned.owner) }
        let duplicate = writer.withLock { writer -> Bool in
            if writer.typed.contains(where: { $0.id == handler.id }) { return true }
            writer.typed.append(handler)
            publish(&writer)
            return false
        }
        if duplicate { throw .duplicateID(handler.id, E.name) }
        flags.bitwiseOr(SlotFlags.typed, ordering: .relaxed)
        if let span { span.flags.flags.bitwiseOr(span.bit, ordering: .relaxed) }
        reclaim()
    }

    func detach(_ id: HandlerID) {
        let removed = writer.withLock { writer -> Bool in
            guard let index = writer.typed.firstIndex(where: { $0.id == id }) else { return false }
            writer.typed.remove(at: index)
            if writer.typed.isEmpty {
                flags.bitwiseAnd(~SlotFlags.typed, ordering: .relaxed)
                if let span { span.flags.flags.bitwiseAnd(~span.bit, ordering: .relaxed) }
            }
            publish(&writer)
            return true
        }
        if removed { reclaim() }
    }

    /// Rebuilds the list against the current erased registry, after it
    /// changed. Called by an emit that noticed, before it reads.
    @usableFromInline
    func refreshErased() {
        writer.withLock { publish(&$0) }
        reclaim()
    }

    /// Swaps in a list built from `writer`, retiring the old one. Under the
    /// writer lock, so two publishes never race.
    private func publish(_ writer: inout Writer) {
        let generation = Registry.erasedGeneration.load(ordering: .acquiring)
        let erased =
            Registry.erasedActive.load(ordering: .relaxed) ? Registry.erasedMatching(E.name) : []
        let list: UInt =
            writer.typed.isEmpty && erased.isEmpty
            ? 0
            : UInt(
                bitPattern: Unmanaged.passRetained(
                    _Handlers<E>(typed: writer.typed, erased: erased)
                ).toOpaque())
        erasedGeneration.store(generation, ordering: .relaxed)
        let old = current.exchange(list, ordering: .sequentiallyConsistent)
        if old != 0 { writer.retired.append(old) }
    }

    /// Frees retired lists after a grace period — unless this thread is
    /// inside a dispatch, where waiting could deadlock; the next grace period
    /// frees them instead.
    private func reclaim() {
        let thread = DispatchThread.current
        guard thread.pointee.depth == 0 else {
            // Inside a dispatch: the outermost one frees it on its way out.
            Registry.deferredReclaims.withLock { $0.append(self) }
            thread.pointee.reclaimDeferred = true
            return
        }
        grace.withLock { completed in
            defer { completed += 1 }
            let retired = writer.withLock { writer in
                defer { writer.retired.removeAll() }
                return writer.retired
            }
            // Nothing retired still means waiting: a detach's guarantee is
            // the wait, whether or not a list needs freeing afterwards.
            let start = epoch.load(ordering: .sequentiallyConsistent)
            for step in 1...2 {
                let draining = (start &+ step &- 1) & 1
                epoch.store(start &+ step, ordering: .sequentiallyConsistent)
                while readers(draining) > 0 { Yield.now() }
            }
            retired.forEach(Self.release)
        }
    }

    private static func release(_ list: UInt) {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: list) else { return }
        Unmanaged<_Handlers<E>>.fromOpaque(pointer).release()
    }

    func reclaimNow() { reclaim() }

    /// Handler lists swapped out and not yet freed — for tests of
    /// reclamation.
    package var retiredCount: Int { writer.withLock { $0.retired.count } }

    private func readers(_ parity: Int) -> Int {
        parity == 0
            ? readersEven.load(ordering: .sequentiallyConsistent)
            : readersOdd.load(ordering: .sequentiallyConsistent)
    }

    // MARK: Span observers

    /// The span observers whose prefix matches the span `name` — cached on
    /// the span's `Start` slot.
    func observers(for name: EventName) -> [ObserverEntry] {
        let generation = Registry.observerGeneration.load(ordering: .acquiring)
        return observerCache.withLock { cache in
            if cache.generation != generation {
                cache = (generation, Registry.observersMatching(name))
            }
            return cache.entries
        }
    }
}

/// The bits of ``HandlerSlot/flags``.
@usableFromInline
enum SlotFlags {
    /// This type has typed handlers.
    @usableFromInline static let typed: UInt8 = 1
    /// An erased handler's prefix matches this slot's event.
    @usableFromInline static let erased: UInt8 = 2
    /// A span observer's prefix matches this slot's span.
    @usableFromInline static let observers: UInt8 = 4
}

/// A slot whose retired lists a dispatch deferred freeing.
protocol DeferredReclaim: AnyObject, Sendable {
    func reclaimNow()
}

/// A slot the registry can reach, to set its erased and observer bits
/// from the prefixes attached.
protocol EnrolledSlot: AnyObject, Sendable {
    /// The event names an erased handler's prefix is matched against.
    var eventNames: [EventName] { get }
    /// The span name a span observer's prefix is matched against; nil for
    /// a slot that is not a span's.
    var spanName: EventName? { get }
    func setGlobal(_ bit: UInt8, _ on: Bool)
}

/// One typed handler, as attached.
struct _TypedHandler<E: TelemetryEvent>: Sendable {
    let id: HandlerID
    let body: TelemetryHandler<E>

    init(id: HandlerID, body: @escaping TelemetryHandler<E>) {
        self.id = id
        self.body = body
    }
}

/// An immutable, published handler list. Read without retaining it: the
/// grace period is what keeps it alive while an emit holds it. Bodies and
/// ids apart, so calling a handler touches nothing else.
@usableFromInline
final class _Handlers<E: TelemetryEvent>: Sendable {
    @usableFromInline let bodies: ContiguousArray<TelemetryHandler<E>>
    @usableFromInline let ids: ContiguousArray<HandlerID>
    @usableFromInline let erased: ContiguousArray<ErasedEntry>

    init(typed: [_TypedHandler<E>], erased: [ErasedEntry]) {
        self.bodies = ContiguousArray(typed.map(\.body))
        self.ids = ContiguousArray(typed.map(\.id))
        self.erased = ContiguousArray(erased)
    }
}

/// An erased handler, with what the detach guarantee needs where a
/// published list cannot give it: an erased handler is cached on every slot
/// it matches, so a detach cannot swap it out of every list at once.
///
/// An invocation announces itself in `inFlight` *before* checking `alive`,
/// and detach clears `alive` *before* waiting for `inFlight` to drain. Both
/// sequentially consistent — the Dekker pattern — so either the invocation
/// sees the handler gone, or detach sees it running and waits.
@usableFromInline
final class ErasedEntry: Sendable {
    let id: HandlerID
    let prefix: EventName
    let handler: ErasedHandler
    let alive = Atomic<Bool>(true)
    let inFlight = Atomic<Int>(0)

    init(id: HandlerID, prefix: EventName, handler: @escaping ErasedHandler) {
        self.id = id
        self.prefix = prefix
        self.handler = handler
    }

    @inline(__always)
    func invoke(_ event: borrowing AnyEvent) throws {
        inFlight.add(1, ordering: .sequentiallyConsistent)
        defer { inFlight.subtract(1, ordering: .sequentiallyConsistent) }
        guard alive.load(ordering: .sequentiallyConsistent) else { return }
        try handler(event)
    }

    func retire() {
        alive.store(false, ordering: .sequentiallyConsistent)
        guard DispatchThread.current.pointee.depth == 0 else { return }
        while inFlight.load(ordering: .sequentiallyConsistent) > 0 { Yield.now() }
    }
}

/// A span observer, with the same guarantee as ``ErasedEntry``.
final class HandlerEntry<Body: Sendable>: Sendable {
    let id: HandlerID
    let body: Body
    let alive = Atomic<Bool>(true)
    let inFlight = Atomic<Int>(0)

    init(id: HandlerID, body: Body) {
        self.id = id
        self.body = body
    }

    /// Runs `call` unless the entry has been detached.
    @inline(__always)
    func invoke(_ call: (Body) throws -> Void) rethrows {
        inFlight.add(1, ordering: .sequentiallyConsistent)
        defer { inFlight.subtract(1, ordering: .sequentiallyConsistent) }
        guard alive.load(ordering: .sequentiallyConsistent) else { return }
        try call(body)
    }

    /// Marks the entry dead and waits out any invocation already under way
    /// — unless this thread is inside a dispatch, for the reason
    /// ``HandlerSlot`` gives.
    func retire() {
        alive.store(false, ordering: .sequentiallyConsistent)
        guard DispatchThread.current.pointee.depth == 0 else { return }
        while inFlight.load(ordering: .sequentiallyConsistent) > 0 { Yield.now() }
    }
}
