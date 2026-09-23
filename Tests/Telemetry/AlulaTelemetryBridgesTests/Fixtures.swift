import Foundation
import Synchronization
import Testing

/// The registry is process-wide, and a bridge attached in one test would
/// otherwise be seen by another's emits — so these run one at a time,
/// under one parent.
@Suite("AlulaTelemetryBridges", .serialized)
struct CoreTests {}

/// Thread-safe collection a handler appends to.
final class Recorder<T: Sendable>: Sendable {
    private let items = Mutex<[T]>([])
    func append(_ item: T) { items.withLock { $0.append(item) } }
    var all: [T] { items.withLock { $0 } }
    var count: Int { items.withLock { $0.count } }
}

final class Flag: Sendable {
    let value = Atomic<Bool>(false)
}
