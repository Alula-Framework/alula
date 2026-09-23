/// A metric declared as data: a reduction over one event type, which a
/// reporter turns into a handler.
///
/// ```swift
/// let metrics: [TelemetryMetric] = [
///     .counter(SessionCreated.self),
///     .distribution(HangarQuery.Stop.self, \.duration, unit: .milliseconds, tags: \.table),
///     .sum(HTTPResponse.self, \.bytesOut, tags: \.route),
///     .counter(HangarQuery.Exception.self, tags: \.errorType, keep: { $0.table != "audit" }),
/// ]
/// ```
///
/// Key paths make a definition type-checked against its event: a measured
/// field must be a ``TelemetryMeasurement`` of the event's `Measurements`,
/// and each tag a ``TagValue`` of its `Metadata`. A tag from another event,
/// or a field that isn't a tag, does not compile.
///
/// Static members rather than `Counter(…)` types: swift-metrics already
/// has a `Counter`, and an application imports both.
public struct TelemetryMetric: Sendable {
    public let descriptor: MetricDescriptor
    private let bind: @Sendable (any MetricRecorder, HandlerID) throws(AttachError) -> HandlerToken

    /// Attaches a handler that feeds every matching emit to `recorder`.
    public func attach(
        recording recorder: some MetricRecorder, id: HandlerID
    ) throws(AttachError) -> HandlerToken {
        try bind(recorder, id)
    }

    // MARK: Definitions

    /// Counts the event.
    ///
    /// Named after the event unless `name` says otherwise.
    public static func counter<E: TelemetryEvent, each Tag: TagValue>(
        _: E.Type,
        name: String? = nil,
        description: String? = nil,
        tags: repeat KeyPath<E.Metadata, each Tag> & Sendable,
        keep: (@Sendable (borrowing E.Metadata) -> Bool)? = nil
    ) -> TelemetryMetric {
        let tagKeys = keys(E.self, repeat each tags)
        let values = tagValues(E.self, repeat each tags)
        return TelemetryMetric(
            descriptor: MetricDescriptor(
                name: name ?? E.name.description, kind: .counter, event: E.name, field: nil,
                unit: nil, buckets: nil, tags: tagKeys, description: description)
        ) { recorder, id throws(AttachError) in
            try Telemetry.attach(E.self, id: id) { _, metadata, _ in
                if let keep, !keep(metadata) { return }
                recorder.record(.integer(1), tags: values(metadata))
            }
        }
    }

    /// Adds up a measurement.
    public static func sum<E: TelemetryEvent, Value: TelemetryMeasurement, each Tag: TagValue>(
        _: E.Type,
        _ field: KeyPath<E.Measurements, Value> & Sendable,
        name: String? = nil,
        unit: MetricUnit? = nil,
        description: String? = nil,
        tags: repeat KeyPath<E.Metadata, each Tag> & Sendable,
        keep: (@Sendable (borrowing E.Metadata) -> Bool)? = nil
    ) -> TelemetryMetric {
        measured(
            .sum, E.self, field, name: name, unit: unit, buckets: nil, description: description,
            tags: repeat each tags, keep: keep)
    }

    /// Reports a measurement's latest value, such as a pool's idle count.
    public static func lastValue<
        E: TelemetryEvent, Value: TelemetryMeasurement, each Tag: TagValue
    >(
        _: E.Type,
        _ field: KeyPath<E.Measurements, Value> & Sendable,
        name: String? = nil,
        unit: MetricUnit? = nil,
        description: String? = nil,
        tags: repeat KeyPath<E.Metadata, each Tag> & Sendable,
        keep: (@Sendable (borrowing E.Metadata) -> Bool)? = nil
    ) -> TelemetryMetric {
        measured(
            .lastValue, E.self, field, name: name, unit: unit, buckets: nil,
            description: description,
            tags: repeat each tags, keep: keep)
    }

    /// Records a measurement's distribution — a timer, for a `Duration`.
    ///
    /// `buckets` is a hint only some reporters honor; `SwiftMetricsReporter`
    /// does not (see ``MetricBuckets``).
    public static func distribution<
        E: TelemetryEvent, Value: TelemetryMeasurement, each Tag: TagValue
    >(
        _: E.Type,
        _ field: KeyPath<E.Measurements, Value> & Sendable,
        name: String? = nil,
        unit: MetricUnit? = nil,
        buckets: MetricBuckets? = nil,
        description: String? = nil,
        tags: repeat KeyPath<E.Metadata, each Tag> & Sendable,
        keep: (@Sendable (borrowing E.Metadata) -> Bool)? = nil
    ) -> TelemetryMetric {
        measured(
            .distribution, E.self, field, name: name, unit: unit, buckets: buckets,
            description: description, tags: repeat each tags, keep: keep)
    }

    // MARK: Plumbing

    private init(
        descriptor: MetricDescriptor,
        bind:
            @escaping @Sendable (any MetricRecorder, HandlerID) throws(AttachError) -> HandlerToken
    ) {
        self.descriptor = descriptor
        self.bind = bind
    }

    private static func measured<
        E: TelemetryEvent, Value: TelemetryMeasurement, each Tag: TagValue
    >(
        _ kind: MetricKind,
        _: E.Type,
        _ field: KeyPath<E.Measurements, Value> & Sendable,
        name: String?,
        unit: MetricUnit?,
        buckets: MetricBuckets?,
        description: String?,
        tags: repeat KeyPath<E.Metadata, each Tag> & Sendable,
        keep: (@Sendable (borrowing E.Metadata) -> Bool)?
    ) -> TelemetryMetric {
        guard let fieldKey = E.Measurements.fieldName(for: field) else {
            preconditionFailure(
                "\(E.name): \(E.Measurements.self).fieldName(for:) has no name for the measured field; "
                    + "a hand-written TelemetryFields conformance must name every field")
        }
        let tagKeys = keys(E.self, repeat each tags)
        let values = tagValues(E.self, repeat each tags)
        return TelemetryMetric(
            descriptor: MetricDescriptor(
                name: name ?? "\(E.name).\(fieldKey)", kind: kind, event: E.name, field: fieldKey,
                unit: unit, buckets: buckets, tags: tagKeys, description: description)
        ) { recorder, id throws(AttachError) in
            try Telemetry.attach(E.self, id: id) { measurements, metadata, _ in
                if let keep, !keep(metadata) { return }
                recorder.record(
                    measurements[keyPath: field].measurementValue, tags: values(metadata))
            }
        }
    }

    private static func keys<E: TelemetryEvent, each Tag: TagValue>(
        _: E.Type, _ tags: repeat KeyPath<E.Metadata, each Tag>
    ) -> [String] {
        var keys: [String] = []
        for tag in repeat each tags {
            guard let key = E.Metadata.fieldName(for: tag) else {
                preconditionFailure(
                    "\(E.name): \(E.Metadata.self).fieldName(for:) has no name for a tag; "
                        + "a hand-written TelemetryFields conformance must name every field")
            }
            keys.append(key)
        }
        return keys
    }

    private static func tagValues<E: TelemetryEvent, each Tag: TagValue>(
        _: E.Type, _ tags: repeat KeyPath<E.Metadata, each Tag> & Sendable
    ) -> @Sendable (borrowing E.Metadata) -> [String] {
        let tags = (repeat each tags)
        return { metadata in
            var values: [String] = []
            for tag in repeat each tags {
                values.append(metadata[keyPath: tag].tagValue)
            }
            return values
        }
    }
}

/// What a metric is, for a reporter to create the instrument it maps to.
public struct MetricDescriptor: Sendable, Hashable {
    /// Dot-separated, like the event's: `hangar.query.stop.duration`. A
    /// reporter adapts it to its backend's naming — swift-metrics' replaces
    /// the dots with underscores.
    public let name: String
    public let kind: MetricKind
    /// The event the metric reduces.
    public let event: EventName
    /// The measured field's name; `nil` for a counter.
    public let field: String?
    /// What a `Duration` measurement is reported in.
    public let unit: MetricUnit?
    public let buckets: MetricBuckets?
    /// The tag names, in the order a recorder receives their values.
    public let tags: [String]
    public let description: String?

    public init(
        name: String, kind: MetricKind, event: EventName, field: String?, unit: MetricUnit?,
        buckets: MetricBuckets?, tags: [String], description: String?
    ) {
        self.name = name
        self.kind = kind
        self.event = event
        self.field = field
        self.unit = unit
        self.buckets = buckets
        self.tags = tags
        self.description = description
    }

    /// A measurement as the number this metric reports: a `Duration` in
    /// ``unit`` (seconds when there is none), anything else as it is.
    public func number(_ value: MeasurementValue) -> Double {
        switch value {
        case .integer(let integer): Double(integer)
        case .double(let double): double
        case .duration(let duration): (unit ?? .seconds).convert(duration)
        }
    }
}

public enum MetricKind: String, Sendable, Hashable {
    case counter, sum, lastValue, distribution
}

/// A unit a `Duration` measurement is reported in.
public enum MetricUnit: String, Sendable, Hashable {
    case nanoseconds, microseconds, milliseconds, seconds

    public func convert(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        let total = Double(seconds) + Double(attoseconds) / 1e18
        return switch self {
        case .nanoseconds: total * 1e9
        case .microseconds: total * 1e6
        case .milliseconds: total * 1e3
        case .seconds: total
        }
    }
}

/// Histogram bucket boundaries — a hint for a reporter whose backend takes
/// them.
///
/// **`SwiftMetricsReporter` does not honor them**: swift-metrics has no way
/// to pass bucket boundaries to a backend, which configures its own (swift-
/// prometheus, for instance, per factory). The hint is carried on the
/// ``MetricDescriptor`` for a reporter that can use it — an OpenTelemetry
/// one with explicit histogram boundaries — and ignored by one that
/// cannot.
public enum MetricBuckets: Sendable, Hashable {
    /// `start`, `start × factor`, … — `count` boundaries.
    case exponential(start: Double, factor: Double, count: Int)
    case explicit([Double])

    public var boundaries: [Double] {
        switch self {
        case .explicit(let boundaries): boundaries
        case .exponential(let start, let factor, let count):
            Array(sequence(first: start, next: { $0 * factor }).prefix(max(count, 0)))
        }
    }
}

/// Where a metric's values go: what a reporter creates per definition.
///
/// Called on the emitting thread, inside a handler: record, don't block.
public protocol MetricRecorder: Sendable {
    /// One observation. `tags` holds the definition's tag values in the
    /// order of ``MetricDescriptor/tags``; it is empty — and costs nothing —
    /// for an untagged metric.
    func record(_ value: MeasurementValue, tags: [String])
}

/// Builds a `[TelemetryMetric]` with `if` and `for` — where an array
/// literal won't do.
@resultBuilder
public enum TelemetryMetricsBuilder {
    public static func buildExpression(_ metric: TelemetryMetric) -> [TelemetryMetric] { [metric] }
    public static func buildExpression(_ metrics: [TelemetryMetric]) -> [TelemetryMetric] {
        metrics
    }
    public static func buildBlock(_ parts: [TelemetryMetric]...) -> [TelemetryMetric] {
        parts.flatMap { $0 }
    }
    public static func buildOptional(_ part: [TelemetryMetric]?) -> [TelemetryMetric] { part ?? [] }
    public static func buildEither(first: [TelemetryMetric]) -> [TelemetryMetric] { first }
    public static func buildEither(second: [TelemetryMetric]) -> [TelemetryMetric] { second }
    public static func buildArray(_ parts: [[TelemetryMetric]]) -> [TelemetryMetric] {
        parts.flatMap { $0 }
    }
}

extension TelemetryMetric {
    /// `TelemetryMetric.all { … }` — the builder, for a list with conditions.
    public static func all(@TelemetryMetricsBuilder _ build: () -> [TelemetryMetric])
        -> [TelemetryMetric]
    {
        build()
    }
}

/// Emitted once per metric when a reporter's cap on tag combinations is
/// reached. Values past the cap are still recorded — under the tag value
/// `_overflow` — so a total stays right while an unbounded label from a
/// library cannot take the metrics backend down.
public enum TelemetryCardinalityExceeded: TelemetryEvent {
    public struct Metadata: TelemetryFields {
        public var metric: String
        public var limit: Int

        public init(metric: String, limit: Int) {
            self.metric = metric
            self.limit = limit
        }

        public func encode(into encoder: inout FieldEncoder) {
            encoder.value("metric", metric)
            encoder.value("limit", limit)
        }

        public static func fieldName(for keyPath: PartialKeyPath<Metadata>) -> String? {
            switch keyPath {
            case \Metadata.metric: "metric"
            case \Metadata.limit: "limit"
            default: nil
            }
        }
    }

    public static let name: EventName = "flight.telemetry.cardinality_exceeded"
    public static let _slot = HandlerSlot<TelemetryCardinalityExceeded>()
}
