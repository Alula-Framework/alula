/// A validated, dot-separated event name: `flight.sessions.created`,
/// `hangar.query.stop`.
///
/// Each segment matches `[a-z][a-z0-9_]*`. The `@TelemetryEvent` macro
/// checks a literal name at compile time; a name built at runtime — an
/// erased handler's prefix — goes through ``init(validating:)``. The
/// segments are split once, at construction, so prefix matching on the
/// dispatch slow path compares arrays rather than re-parsing strings.
public struct EventName: Sendable, Hashable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let description: String
    /// The name split on `.`, kept so prefix matching is segment-wise:
    /// `flight.http` is a prefix of `flight.http.request`, not of
    /// `flight.https`.
    public let segments: [Substring]

    /// A name known to be valid — a literal the macro already checked, or
    /// one ``init(validating:)`` accepted.
    public init(stringLiteral value: String) {
        precondition(
            Self.isValid(value),
            "'\(value)' is not a telemetry event name: dot-separated segments of [a-z][a-z0-9_]*")
        self.init(unchecked: value)
    }

    /// Checks `value` against the grammar and throws when it does not match.
    public init(validating value: String) throws(EventNameError) {
        guard Self.isValid(value) else { throw EventNameError(name: value) }
        self.init(unchecked: value)
    }

    private init(unchecked value: String) {
        self.description = value
        self.segments = value.split(separator: ".", omittingEmptySubsequences: false)
    }

    /// The prefix of every name — for an erased handler or a span observer
    /// that wants everything, such as a development log or a tracer. Not a
    /// name any event can have.
    public static let all = EventName(root: ())

    private init(root: Void) {
        self.description = "*"
        self.segments = []
    }

    /// Whether this name is `prefix` or lies beneath it, segment by segment.
    public func hasPrefix(_ prefix: EventName) -> Bool {
        prefix.segments.count <= segments.count
            && zip(prefix.segments, segments).allSatisfy { $0 == $1 }
    }

    /// Appends a segment: `name.appending("stop")`.
    public func appending(_ segment: String) -> EventName {
        EventName(stringLiteral: segments.isEmpty ? segment : description + "." + segment)
    }

    public static func == (lhs: EventName, rhs: EventName) -> Bool {
        lhs.description == rhs.description
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(description) }

    /// `segment(.segment)*`, each segment `[a-z][a-z0-9_]*`. Public so the
    /// macro and a runtime caller apply the same rule.
    public static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        for segment in value.split(separator: ".", omittingEmptySubsequences: false) {
            guard let first = segment.unicodeScalars.first, ("a"..."z").contains(first) else {
                return false
            }
            for scalar in segment.unicodeScalars.dropFirst() {
                guard ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_"
                else { return false }
            }
        }
        return true
    }
}

/// A name that does not match ``EventName``'s grammar.
public struct EventNameError: Error, Sendable, Equatable, CustomStringConvertible {
    public let name: String
    public var description: String {
        "'\(name)' is not a telemetry event name: dot-separated segments of [a-z][a-z0-9_]*"
    }
}
