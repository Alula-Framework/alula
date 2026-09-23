#if canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Darwin)
    import Darwin
#endif

/// A value behind a pthread mutex: `Synchronization.Mutex`'s job, done by
/// the platform lock.
///
/// Because ThreadSanitizer cannot see `Mutex` on Linux. Its lock and unlock
/// live in the uninstrumented standard library and hand off through a
/// futex, so TSan never learns that one critical section happens before
/// the next, and reports every contended one as a race — four threads
/// appending to an array inside `Mutex.withLock` are enough (D42). The
/// telemetry spec requires a ThreadSanitizer-clean stress test, and a gate
/// that cries wolf on every lock is no gate. TSan intercepts
/// `pthread_mutex_lock`, so this one it sees.
///
/// `@unchecked Sendable` — the one place this package asserts it: the state
/// is reachable only inside `withLock`, under the mutex.
package final class Lock<State: ~Copyable>: @unchecked Sendable {
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>
    private var state: State

    package init(_ state: consuming State) {
        self.mutex = .allocate(capacity: 1)
        self.mutex.initialize(to: pthread_mutex_t())
        pthread_mutex_init(mutex, nil)
        self.state = state
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
    }

    package func withLock<Result: ~Copyable, Failure: Error>(
        _ body: (inout State) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        return try body(&state)
    }
}
