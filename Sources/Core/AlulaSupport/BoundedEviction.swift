/// The eviction rule of Alula's bounded in-memory stores: sessions,
/// one-time tokens, rate-limit keys.
package enum BoundedEviction {
    /// Brings `entries` back under `maxEntries`, running under the caller's
    /// lock. Nothing happens while the map is within its bound.
    ///
    /// Expired entries go first. If that is not enough, the entries that sort
    /// first by `order` go — least recently used, or soonest to expire — in a
    /// batch of a sixteenth of the bound beyond the excess, so the O(n log n)
    /// sort is paid once per batch rather than on every insert made while
    /// the map is full.
    package static func enforce<Key: Hashable, Value, Order: Comparable>(
        _ entries: inout [Key: Value], maxEntries: Int,
        isExpired: (Value) -> Bool, order: (Value) -> Order
    ) {
        guard entries.count > maxEntries else { return }
        entries = entries.filter { !isExpired($0.value) }
        guard entries.count > maxEntries else { return }
        let excess = entries.count - maxEntries + max(1, maxEntries / 16)
        for (key, _) in entries.sorted(by: { order($0.value) < order($1.value) }).prefix(excess) {
            entries.removeValue(forKey: key)
        }
    }
}
