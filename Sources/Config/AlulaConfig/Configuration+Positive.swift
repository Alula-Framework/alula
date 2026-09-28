/// A configured number that cannot be used where a positive one is needed:
/// zero or less, not finite, or too large to become a `Duration`.
///
/// Thrown by the `Configuration.positive…` helpers. A module usually turns
/// it into its own configuration error through the helper's `orThrow:`, so
/// the operator still sees that module's error type, and this wording.
package struct NonPositiveConfigValue: Error, Sendable, CustomStringConvertible {
    package let key: String
    /// The value as it was read — `0`, `-3`, `inf`, `nan`.
    package let value: String

    package var description: String { "\(key) must be positive; it is \(value)" }
}

// The rule "a positive number, or a startup error naming the key" was written
// by hand at about fifteen sites. Doubles were where it went wrong: `inf`
// passes `> 0`, `nan` fails `<= 0`, and either then traps converting to a
// `Duration` or an integer — `web.request-timeout-seconds: inf` stopped the
// process at boot instead of naming the key.
extension Configuration {
    /// The largest number of seconds the seconds helpers accept: about 31
    /// million years, and small enough that the value survives conversion to
    /// a `Duration` or to whole milliseconds without trapping.
    package static let maximumSeconds: Double = 1e15

    /// `key` as a positive integer, or nil when it is absent.
    ///
    /// - Throws: what `getIfPresent` throws for a malformed value; and for
    ///   zero or less, `wrap` applied to a ``NonPositiveConfigValue``.
    package func positive(
        _ key: String, formerly: [String] = [],
        orThrow wrap: (NonPositiveConfigValue) -> any Error = { $0 }
    ) throws -> Int? {
        guard let value = try getIfPresent(key, formerly: formerly, as: Int.self) else {
            return nil
        }
        guard value > 0 else { throw wrap(NonPositiveConfigValue(key: key, value: "\(value)")) }
        return value
    }

    /// `key`, a number of seconds, as a positive `Duration`, or nil when it
    /// is absent. Fractions are kept: `0.25` is 250 milliseconds.
    ///
    /// - Throws: what `getIfPresent` throws for a malformed value; and for
    ///   zero or less, `inf`, `nan`, or more than ``maximumSeconds``, `wrap`
    ///   applied to a ``NonPositiveConfigValue``.
    package func positiveSeconds(
        _ key: String, formerly: [String] = [],
        orThrow wrap: (NonPositiveConfigValue) -> any Error = { $0 }
    ) throws -> Duration? {
        guard let value = try getIfPresent(key, formerly: formerly, as: Double.self) else {
            return nil
        }
        guard value > 0, value <= Self.maximumSeconds else {
            throw wrap(NonPositiveConfigValue(key: key, value: "\(value)"))
        }
        return .seconds(value)
    }

    /// `key`, a number of seconds where 0 turns the feature off.
    ///
    /// Nil when the key is absent — the caller applies its default with
    /// `??` — `.some(nil)` when it is 0 or less, and the `Duration` when it
    /// is positive. Less than 0 disables too, as every such key read before
    /// this helper did.
    ///
    /// - Throws: what `getIfPresent` throws for a malformed value; and for
    ///   `inf`, `nan`, or more than ``maximumSeconds``, `wrap` applied to a
    ///   ``NonPositiveConfigValue``.
    package func secondsOrDisabled(
        _ key: String, formerly: [String] = [],
        orThrow wrap: (NonPositiveConfigValue) -> any Error = { $0 }
    ) throws -> Duration?? {
        guard let value = try getIfPresent(key, formerly: formerly, as: Double.self) else {
            return nil
        }
        guard value.isFinite, value <= Self.maximumSeconds else {
            throw wrap(NonPositiveConfigValue(key: key, value: "\(value)"))
        }
        return .some(value > 0 ? .seconds(value) : nil)
    }
}
