import CoreMetrics
import Synchronization
import TelemetryCore

/// Reports metric definitions through swift-metrics — to whatever backend
/// the application bootstrapped, Prometheus, StatsD, OpenTelemetry.
///
/// ```swift
/// let tokens = try SwiftMetricsReporter().attach(metrics)
/// ```
///
/// | Definition | swift-metrics |
/// | --- | --- |
/// | counter | `Counter.increment()` |
/// | sum | `Counter.increment(by:)`, or `FloatingPointCounter` for a fractional value |
/// | lastValue | `Gauge.record` |
/// | distribution of a `Duration` | `Timer.recordNanoseconds` |
/// | distribution of a number | `Recorder(aggregate: true).record` |
///
/// Bucket hints (`MetricBuckets`) are not passed on: swift-metrics has no
/// API for them, and the backend configures its own histogram boundaries.
///
/// Names become labels with the dots replaced — `alula.sessions.created`
/// is `alula_sessions_created` — and tags become dimensions. The reporter
/// translates and never aggregates; the backend does.
///
/// **Cardinality.** Each definition keeps at most ``cardinalityLimit`` tag
/// combinations. Past it, values are recorded with every tag set to
/// `_overflow` and `TelemetryCardinalityExceeded` is emitted once for the
/// metric: the totals stay right, and a label nobody meant to be unbounded
/// cannot take the backend down with it.
public struct SwiftMetricsReporter: Sendable {
    /// Where instruments are made; nil means `MetricsSystem.factory`, read
    /// when each instrument is first made rather than when the reporter is.
    public let factory: (any MetricsFactory)?
    public let cardinalityLimit: Int

    /// - Parameters:
    ///   - factory: Where instruments are made. Unless given, the
    ///     application's bootstrapped `MetricsSystem.factory` — looked up at
    ///     each instrument's first use, so a reporter attached before the
    ///     backend was bootstrapped still reports to it.
    ///   - cardinalityLimit: Tag combinations kept per metric.
    public init(factory: (any MetricsFactory)? = nil, cardinalityLimit: Int = 1000) {
        precondition(cardinalityLimit > 0, "cardinalityLimit must be positive")
        self.factory = factory
        self.cardinalityLimit = cardinalityLimit
    }

    /// Attaches a handler per definition; they detach when the returned
    /// tokens do.
    ///
    /// - Throws: `AttachError` when two definitions of one event share a
    ///   name. (Across events, `AlulaTelemetryModule` refuses it earlier.)
    public func attach(
        _ metrics: [TelemetryMetric], id: String = "alula.telemetry.swift-metrics"
    ) throws(AttachError) -> HandlerTokens {
        var tokens = HandlerTokens()
        for metric in metrics {
            let recorder = SwiftMetricsRecorder(
                descriptor: metric.descriptor, factory: factory, limit: cardinalityLimit)
            tokens.append(
                try metric.attach(recording: recorder, id: "\(id):\(metric.descriptor.name)"))
        }
        return tokens
    }

    /// A metric name as a swift-metrics label: `alula.sessions.created` is
    /// `alula_sessions_created`. Anything outside `[A-Za-z0-9_:]` becomes
    /// `_`, which is what every common backend accepts.
    public static func label(for name: String) -> String {
        String(
            String.UnicodeScalarView(
                name.unicodeScalars.map { scalar in
                    switch scalar {
                    case "a"..."z", "A"..."Z", "0"..."9", "_", ":": scalar
                    default: "_"
                    }
                }))
    }
}

/// One definition's instruments, one per tag combination.
final class SwiftMetricsRecorder: MetricRecorder {
    private enum Instrument: Sendable {
        case counter(Counter)
        case floatingPointCounter(FloatingPointCounter)
        case gauge(Gauge)
        case timer(CoreMetrics.Timer)
        case recorder(Recorder)
    }

    private let descriptor: MetricDescriptor
    private let label: String
    private let explicitFactory: (any MetricsFactory)?
    private let limit: Int
    private let instruments = Mutex<[[String]: Instrument]>([:])
    private let overflowReported = Atomic<Bool>(false)

    init(descriptor: MetricDescriptor, factory: (any MetricsFactory)?, limit: Int) {
        self.descriptor = descriptor
        self.label = SwiftMetricsReporter.label(for: descriptor.name)
        self.explicitFactory = factory
        self.limit = limit
    }

    func record(_ value: MeasurementValue, tags: [String]) {
        let (instrument, overflowed) = instruments.withLock { instruments in
            if let existing = instruments[tags] { return (existing, false) }
            var key = tags
            var overflowed = false
            if instruments.count >= limit {
                key = Array(repeating: "_overflow", count: tags.count)
                overflowed = true
                if let existing = instruments[key] { return (existing, true) }
            }
            let made = make(for: value, tags: key)
            instruments[key] = made
            return (made, overflowed)
        }
        // Outside the lock: a handler of this event may itself record.
        if overflowed, !overflowReported.exchange(true, ordering: .relaxed) {
            Telemetry.emit(TelemetryCardinalityExceeded.self) {
                .init(metric: descriptor.name, limit: limit)
            }
        }
        switch instrument {
        case .counter(let counter):
            if case .integer(let integer) = value {
                counter.increment(by: integer)
            } else {
                counter.increment(by: Int64(descriptor.number(value)))
            }
        case .floatingPointCounter(let counter): counter.increment(by: descriptor.number(value))
        case .gauge(let gauge): gauge.record(descriptor.number(value))
        case .timer(let timer):
            if case .duration(let duration) = value {
                let (seconds, attoseconds) = duration.components
                timer.recordNanoseconds(seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
            } else {
                timer.recordNanoseconds(Int64(descriptor.number(value)))
            }
        case .recorder(let recorder): recorder.record(descriptor.number(value))
        }
    }

    /// The instrument a definition maps to, chosen on the first value: a
    /// sum of integers counts, a sum of anything else is fractional.
    private func make(for value: MeasurementValue, tags: [String]) -> Instrument {
        let factory = explicitFactory ?? MetricsSystem.factory
        let dimensions = Array(zip(descriptor.tags, tags))
        switch descriptor.kind {
        case .counter:
            return .counter(Counter(label: label, dimensions: dimensions, factory: factory))
        case .sum:
            if case .integer = value {
                return .counter(Counter(label: label, dimensions: dimensions, factory: factory))
            }
            return .floatingPointCounter(
                FloatingPointCounter(label: label, dimensions: dimensions, factory: factory))
        case .lastValue:
            return .gauge(Gauge(label: label, dimensions: dimensions, factory: factory))
        case .distribution:
            if case .duration = value {
                return .timer(
                    CoreMetrics.Timer(
                        label: label, dimensions: dimensions,
                        preferredDisplayUnit: descriptor.unit.map(Self.timeUnit) ?? .seconds,
                        factory: factory))
            }
            return .recorder(
                Recorder(label: label, dimensions: dimensions, aggregate: true, factory: factory))
        }
    }

    private static func timeUnit(_ unit: MetricUnit) -> TimeUnit {
        switch unit {
        case .nanoseconds: .nanoseconds
        case .microseconds: .microseconds
        case .milliseconds: .milliseconds
        case .seconds: .seconds
        }
    }
}
