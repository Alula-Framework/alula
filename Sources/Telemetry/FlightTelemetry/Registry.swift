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
    /// True iff any erased handler is attached. Mirrored into every slot's
    /// flags, which is what an emit reads.
    static let erasedActive = Atomic<Bool>(false)
    @usableFromInline static let erasedGeneration = Atomic<UInt64>(0)
    static let erased = Lock<[ErasedEntry]>([])

    /// True iff any span observer is attached. Mirrored like `erasedActive`.
    static let observersActive = Atomic<Bool>(false)
    static let observerGeneration = Atomic<UInt64>(0)
    static let observers = Lock<[ObserverEntry]>([])

    static let names = Lock<[String: ObjectIdentifier]>([:])

    /// Every slot created, and the bits they all share. A slot enrolls when
    /// it is created — the first emit or attach of its type — and takes the
    /// bits as they stand, under the same lock that changes them.
    static let enrolled = Lock<(slots: [any EnrolledSlot], erased: Bool, observers: Bool)>(
        ([], false, false))

    static func enroll(_ slot: some EnrolledSlot) {
        enrolled.withLock { state in
            state.slots.append(slot)
            if state.erased { slot.setGlobal(SlotFlags.erased, true) }
            if state.observers { slot.setGlobal(SlotFlags.observers, true) }
        }
    }

    /// Sets a shared bit on every slot. Called under the lock of the list
    /// it summarizes, so two changes to it cannot land out of order.
    private static func setGlobal(_ bit: UInt8, _ on: Bool) {
        enrolled.withLock { state in
            if bit == SlotFlags.erased { state.erased = on } else { state.observers = on }
            for slot in state.slots { slot.setGlobal(bit, on) }
        }
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
            if entries.count == 1 {
                erasedActive.store(true, ordering: .relaxed)
                setGlobal(SlotFlags.erased, true)
            }
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
            if entries.isEmpty {
                erasedActive.store(false, ordering: .relaxed)
                setGlobal(SlotFlags.erased, false)
            }
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
            if entries.count == 1 {
                observersActive.store(true, ordering: .relaxed)
                setGlobal(SlotFlags.observers, true)
            }
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
            if entries.isEmpty {
                observersActive.store(false, ordering: .relaxed)
                setGlobal(SlotFlags.observers, false)
            }
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
    static func register(_ name: EventName, _ type: Any.Type) {
        let id = ObjectIdentifier(type)
        let clash = names.withLock { names -> Bool in
            if let owner = names[name.description] { return owner != id }
            names[name.description] = id
            return false
        }
        guard clash else { return }
        let message = "two telemetry event types are named \(name); the second is \(type)"
        assertionFailure(message)
        let first = warnedNames.withLock { $0.insert(name.description).inserted }
        if first { TelemetryDiagnostics.warn(message) }
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
