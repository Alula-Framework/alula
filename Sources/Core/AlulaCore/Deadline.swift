/// When the work in progress must be finished by: set by Alula Web for a
/// request with a timeout, and readable by anything the request calls.
///
/// ```swift
/// let budget = Deadline.remaining ?? .seconds(30)
/// ```
///
/// A task-local, so it follows the request into every function and child task
/// it awaits without being passed. Alula's own outbound HTTP client shrinks
/// its timeout to what is left. There is no point waiting 30 seconds for a
/// downstream answer when the caller gives up in 5.
public enum Deadline {
    @TaskLocal public static var current: ContinuousClock.Instant?

    /// Time left before `current`, zero once it has passed; nil with no deadline.
    public static var remaining: Duration? {
        current.map { max(.zero, ContinuousClock.now.duration(to: $0)) }
    }
}
