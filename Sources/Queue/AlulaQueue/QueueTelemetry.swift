import Foundation

#if Telemetry
    import TelemetryCore
    import TelemetryMacros

    /// What the queue reports, as telemetry events, when the `Telemetry`
    /// trait is on. `AlulaTelemetryModule` reports ``QueueMetrics/definitions``.
    ///
    /// Dimensions are job kinds and queue names, which are fixed by the code,
    /// never job ids or payloads.
    public enum QueueEvents {
        /// A job was enqueued.
        @TelemetryEvent("alula.queue.enqueued")
        public enum Enqueued {
            public struct Metadata {
                public var kind: String
                public var queue: String
            }
        }

        /// A worker finished an attempt.
        @TelemetryEvent("alula.queue.attempt")
        public enum Attempt {
            public struct Metadata {
                public var kind: String
                public var queue: String
                /// `completed`, `retrying`, `discarded` or `superseded`.
                public var outcome: String
            }
            public struct Measurements {
                /// How long the handler ran.
                public var duration: Duration
                /// From enqueue to this attempt's start. Includes any delay the
                /// job was enqueued with, and earlier attempts' backoff.
                public var wait: Duration
            }
        }

        /// Renewing held leases failed. Jobs whose leases lapse are run again
        /// by another worker.
        @TelemetryEvent("alula.queue.lease_renewal_failed")
        public enum LeaseRenewalFailed {}

        /// Claiming from a queue failed.
        @TelemetryEvent("alula.queue.claim_failed")
        public enum ClaimFailed {
            public struct Metadata {
                public var queue: String
            }
        }

        /// A queue's depth, sampled by each worker at its poll interval.
        @TelemetryEvent("alula.queue.depth")
        public enum Depth {
            public struct Metadata {
                public var queue: String
            }
            public struct Measurements {
                /// Waiting, including scheduled and backing-off jobs.
                public var available: Int
                public var running: Int
                /// Dead letters not yet pruned.
                public var discarded: Int
            }
        }
    }

    /// The queue's metrics over ``QueueEvents``.
    public enum QueueMetrics {
        public static let definitions: [TelemetryMetric] = [
            .counter(
                QueueEvents.Enqueued.self, name: "alula.queue.enqueued", tags: \.queue, \.kind),
            .counter(
                QueueEvents.Attempt.self, name: "alula.queue.attempts",
                tags: \.queue, \.kind, \.outcome),
            .distribution(
                QueueEvents.Attempt.self, \.duration, name: "alula.queue.duration",
                tags: \.queue, \.kind),
            .distribution(
                QueueEvents.Attempt.self, \.wait, name: "alula.queue.wait", tags: \.queue, \.kind),
            .counter(
                QueueEvents.LeaseRenewalFailed.self, name: "alula.queue.lease_renewal_failures"),
            .counter(
                QueueEvents.ClaimFailed.self, name: "alula.queue.claim_failures", tags: \.queue),
            .lastValue(
                QueueEvents.Depth.self, \.available, name: "alula.queue.available", tags: \.queue),
            .lastValue(
                QueueEvents.Depth.self, \.running, name: "alula.queue.running", tags: \.queue),
            .lastValue(
                QueueEvents.Depth.self, \.discarded, name: "alula.queue.discarded", tags: \.queue),
        ]
    }
#endif

/// Emission points, compiled to nothing without the `Telemetry` trait, so the
/// queue's own code has no `#if` in it.
enum QueueTelemetry {
    static func enqueued(kind: String, queue: String) {
        #if Telemetry
            Telemetry.emit(QueueEvents.Enqueued.self) { .init(kind: kind, queue: queue) }
        #endif
    }

    static func attempt(
        _ job: ClaimedJob, outcome: QueueAttemptOutcome, duration: Duration, startedAt: Date
    ) {
        #if Telemetry
            Telemetry.emit(QueueEvents.Attempt.self) {
                let name =
                    switch outcome {
                    case .completed: "completed"
                    case .retrying: "retrying"
                    case .discarded: "discarded"
                    case .superseded: "superseded"
                    }
                let wait = max(0, startedAt.timeIntervalSince(job.enqueuedAt))
                return (
                    .init(duration: duration, wait: .milliseconds(Int64(wait * 1000))),
                    .init(kind: job.kind, queue: job.queue, outcome: name)
                )
            }
        #endif
    }

    static func leaseRenewalFailed() {
        #if Telemetry
            Telemetry.emit(QueueEvents.LeaseRenewalFailed.self)
        #endif
    }

    static func claimFailed(queue: String) {
        #if Telemetry
            Telemetry.emit(QueueEvents.ClaimFailed.self) { .init(queue: queue) }
        #endif
    }

    static func depth(queue: String, _ counts: QueueCounts) {
        #if Telemetry
            Telemetry.emit(QueueEvents.Depth.self) {
                (
                    .init(
                        available: counts.available, running: counts.running,
                        discarded: counts.discarded),
                    .init(queue: queue)
                )
            }
        #endif
    }

    /// Whether sampling depth would reach anyone: it costs a store query.
    static var reportsDepth: Bool {
        #if Telemetry
            Telemetry.isEnabled(QueueEvents.Depth.self)
        #else
            false
        #endif
    }
}
