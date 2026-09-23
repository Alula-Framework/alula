import Foundation
import Synchronization

#if canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Darwin)
    import Darwin
#endif

/// An erased handler: every event whose name lies under `prefix`, seen
/// through ``AnyEvent``.
@usableFromInline typealias ErasedHandler = @Sendable (borrowing AnyEvent) throws -> Void

/// A span observer, type-erased.
typealias ObserverEntry = HandlerEntry<(prefix: EventName, observer: AnySpanObserver)>

/// The process-wide registry: erased handlers, span observers, and the
/// name → type map that catches two event types claiming one name.
///
/// Global on purpose. A registry scoped per task would cost a task-local
/// read on every emit, which is the one thing the emit path may not do.
/// Isolation is what tests need, and `FlightTelemetryTesting` gets it inside
/// its handlers instead.
@usableFromInline
enum Registry {
    /// True iff any erased handler is attached, anywhere. The slow path's
    /// shortcut; the fast path reads per-slot bits instead.
    static let erasedActive = Atomic<Bool>(false)
    @usableFromInline static let erasedGeneration = Atomic<UInt64>(0)
    static let erased = Lock<[ErasedEntry]>([])

    /// True iff any span observer is attached, anywhere.
    static let observersActive = Atomic<Bool>(false)
    static let observerGeneration = Atomic<UInt64>(0)
    static let observers = Lock<[ObserverEntry]>([])

    static let names = Lock<[String: (id: ObjectIdentifier, type: String)]>([:])

    /// Slots whose retired lists wait for a dispatch to end.
    static let deferredReclaims = Lock<[any DeferredReclaim]>([])

    /// Frees what dispatches deferred — called by the outermost one, at
    /// depth zero, where waiting for a grace period is safe.
    @usableFromInline @inline(never)
    static func reclaimDeferred(_ thread: UnsafeMutablePointer<DispatchThread>) {
        thread.pointee.reclaimDeferred = false
        let slots = deferredReclaims.withLock { slots in
            defer { slots.removeAll() }
            return slots
        }
        for slot in slots { slot.reclaimNow() }
    }

    /// Every slot created, and the prefixes of every erased handler and span
    /// observer attached. A slot's erased and observer bits are set only when
    /// one of those prefixes matches a name the slot answers to — so a
    /// narrow prefix, `flight.sessions`, costs nothing to `hangar.query`.
    ///
    /// A slot enrolls when it is created (the first emit or attach of its
    /// type) and takes its bits from the prefixes as they stand, under the
    /// same lock that changes them.
    struct Enrolled {
        var slots: [any EnrolledSlot] = []
        var erasedPrefixes: [EventName] = []
        var observerPrefixes: [EventName] = []
    }
    static let enrolled = Lock(Enrolled())

    static func enroll(_ slot: some EnrolledSlot) {
        enrolled.withLock { state in
            state.slots.append(slot)
            apply(to: slot, state)
        }
    }

    /// Replaces a prefix list and resets every slot's bits from it. Called
    /// under the lock of the list it mirrors, so two changes to it cannot
    /// land out of order.
    private static func setPrefixes(erased: [EventName]? = nil, observers: [EventName]? = nil) {
        enrolled.withLock { state in
            if let erased { state.erasedPrefixes = erased }
            if let observers { state.observerPrefixes = observers }
            for slot in state.slots { apply(to: slot, state) }
        }
    }

    private static func apply(to slot: any EnrolledSlot, _ state: Enrolled) {
        // `.all` as a slot's name means "not known": matched by every prefix.
        func matches(_ name: EventName, _ prefix: EventName) -> Bool {
            name.segments.isEmpty || name.hasPrefix(prefix)
        }
        let names = slot.eventNames
        let erased = state.erasedPrefixes.contains { prefix in
            names.contains { matches($0, prefix) }
        }
        slot.setGlobal(SlotFlags.erased, erased)
        let observed =
            slot.spanName.map { span in
                state.observerPrefixes.contains { matches(span, $0) }
            } ?? false
        slot.setGlobal(SlotFlags.observers, observed)
    }
    static let warnedNames = Lock<Set<String>>([])

    // MARK: Erased handlers

    static func attachErased(_ entry: ErasedEntry) throws(AttachError) {
        let duplicate = erased.withLock { entries -> Bool in
            if entries.contains(where: { $0.id == entry.id && $0.prefix == entry.prefix }) {
                return true
            }
            entries.append(entry)
            erasedGeneration.add(1, ordering: .releasing)
            erasedActive.store(true, ordering: .relaxed)
            setPrefixes(erased: entries.map(\.prefix))
            return false
        }
        if duplicate { throw .duplicateID(entry.id, entry.prefix) }
    }

    static func detachErased(_ entry: ErasedEntry) {
        erased.withLock { entries in
            let before = entries.count
            entries.removeAll { $0 === entry }
            guard entries.count != before else { return }
            erasedGeneration.add(1, ordering: .releasing)
            if entries.isEmpty { erasedActive.store(false, ordering: .relaxed) }
            setPrefixes(erased: entries.map(\.prefix))
        }
        entry.retire()
    }

    static func erasedMatching(_ name: EventName) -> [ErasedEntry] {
        erased.withLock { $0.filter { name.hasPrefix($0.prefix) } }
    }

    // MARK: Span observers

    static func attachObserver(_ entry: ObserverEntry) throws(AttachError) {
        let duplicate = observers.withLock { entries -> Bool in
            if entries.contains(where: { $0.id == entry.id && $0.body.prefix == entry.body.prefix })
            {
                return true
            }
            entries.append(entry)
            observerGeneration.add(1, ordering: .releasing)
            observersActive.store(true, ordering: .relaxed)
            setPrefixes(observers: entries.map(\.body.prefix))
            return false
        }
        if duplicate { throw .duplicateID(entry.id, entry.body.prefix) }
    }

    static func detachObserver(_ entry: ObserverEntry) {
        observers.withLock { entries in
            let before = entries.count
            entries.removeAll { $0 === entry }
            guard entries.count != before else { return }
            observerGeneration.add(1, ordering: .releasing)
            if entries.isEmpty { observersActive.store(false, ordering: .relaxed) }
            setPrefixes(observers: entries.map(\.body.prefix))
        }
        entry.retire()
    }

    static func observersMatching(_ name: EventName) -> [ObserverEntry] {
        observers.withLock { $0.filter { name.hasPrefix($0.body.prefix) } }
    }

    // MARK: Names

    /// Records that `type` owns `name`. Called on first attach and first
    /// slow-path dispatch per type. Two types claiming one name is a bug the
    /// compiler cannot see across modules: an assertion in debug, a warning
    /// once in release.
    /// Records that `type` owns `name`, and answers whether it does: the
    /// first type to be touched with a name owns it; any other claiming it
    /// is refused, by name, here — where the slot is created — rather than
    /// after both have emitted conflicting schemas under one identity.
    static func register(_ name: EventName, _ type: Any.Type) -> (owns: Bool, owner: String) {
        let id = ObjectIdentifier(type)
        let described = String(reflecting: type)
        let owner = names.withLock { names -> (id: ObjectIdentifier, type: String) in
            if let owner = names[name.description] { return owner }
            names[name.description] = (id, described)
            return (id, described)
        }
        guard owner.id != id else { return (true, described) }
        let first = warnedNames.withLock { $0.insert(name.description).inserted }
        if first {
            TelemetryDiagnostics.warn(
                "two telemetry event types are named \(name): \(owner.type) owns it, so \(described) "
                    + "is refused — its emits go nowhere and attaching to it throws. Rename one.")
        }
        return (false, owner.type)
    }
}

/// Warnings the runtime prints itself. Core has no logging dependency, so
/// these go to standard error — they are for a developer reading the
/// console, and each is printed at most once.
enum TelemetryDiagnostics {
    static func warn(_ message: String) {
        FileHandle.standardError.write(Data("warning: [FlightTelemetry] \(message)\n".utf8))
    }
}

/// What dispatch keeps per thread: one pointer, read once per emit.
///
/// Thread-local rather than task-local on purpose: dispatch is synchronous,
/// so the thread *is* the call stack, and a task-local read costs several
/// times a thread-local one.
@usableFromInline
struct DispatchThread {
    /// How deep dispatch has re-entered on this thread: a handler that
    /// emits, whose handler emits, and so on. Past ``limit`` nested emits
    /// are dropped. Nonzero also means "inside a handler", where detaching
    /// must not wait.
    @usableFromInline var depth = 0

    /// A slot on this thread retired a handler list from inside a dispatch,
    /// where it could not wait for a grace period. The outermost dispatch
    /// frees it on the way out.
    @usableFromInline var reclaimDeferred = false

    @usableFromInline static let limit = 8

    /// This thread's state, created on first use and freed with the thread.
    @inlinable
    static var current: UnsafeMutablePointer<DispatchThread> {
        @inline(__always) get {
            if let state = pthread_getspecific(key) {
                return state.assumingMemoryBound(to: DispatchThread.self)
            }
            return make()
        }
    }

    @usableFromInline
    static let key: pthread_key_t = {
        var key = pthread_key_t()
        #if canImport(Darwin)
            pthread_key_create(&key) { $0.deallocate() }
        #else
            pthread_key_create(&key) { $0?.deallocate() }
        #endif
        return key
    }()

    @usableFromInline @inline(never)
    static func make() -> UnsafeMutablePointer<DispatchThread> {
        let state = UnsafeMutablePointer<DispatchThread>.allocate(capacity: 1)
        state.initialize(to: DispatchThread())
        pthread_setspecific(key, state)
        return state
    }
}

/// Gives up the rest of this thread's time slice, while a detach waits for
/// an invocation already under way to finish.
enum Yield {
    static func now() { sched_yield() }
}
