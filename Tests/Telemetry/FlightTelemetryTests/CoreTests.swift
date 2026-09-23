import FlightTelemetry
import ServiceContextModule
import Synchronization
import Testing

/// The registry is process-wide, and an erased handler switches on every
/// event's slow path — so these run one at a time, under one parent.
@Suite("FlightTelemetry core", .serialized)
struct CoreTests {}

extension CoreTests {
    @Suite("Event names")
    struct EventNameTests {
        @Test("the grammar: dot-separated segments of [a-z][a-z0-9_]*")
        func grammar() {
            for valid in ["a", "flight.http.request", "hangar.pool_checkout", "x1.y_2"] {
                #expect(EventName.isValid(valid), "\(valid)")
            }
            for invalid in ["", "Flight", "a..b", ".a", "a.", "1a", "a-b", "a.B", "a b"] {
                #expect(!EventName.isValid(invalid), "\(invalid)")
            }
            #expect(throws: EventNameError.self) { try EventName(validating: "Bad.Name") }
        }

        @Test("prefixes match whole segments")
        func prefix() {
            let name: EventName = "flight.http.request"
            #expect(name.hasPrefix("flight"))
            #expect(name.hasPrefix("flight.http"))
            #expect(name.hasPrefix("flight.http.request"))
            #expect(!name.hasPrefix("flight.htt"))
            #expect(!EventName("flight.https").hasPrefix("flight.http"))
        }
    }

}

extension CoreTests {
    @Suite("Emitting and typed handlers")
    struct EmitTests {
        @Test("with nothing attached, the payload closure never runs")
        func payloadNotBuilt() {
            let built = Atomic<Int>(0)
            Telemetry.emit(QueryA.self) {
                built.add(1, ordering: .relaxed)
                return (.init(duration: .zero, rows: 0), .init(table: "t"))
            }
            #expect(built.load(ordering: .relaxed) == 0)
            #expect(!Telemetry.isEnabled(QueryA.self))
        }

        @Test("a typed handler gets the payload by type, and the emit's context")
        func typedHandler() throws {
            let seen = Recorder<(Int, String, TelemetrySpanID?)>()
            let token = try Telemetry.attach(QueryB.self, id: "test") {
                measurements, metadata, context in
                seen.append((measurements.rows, metadata.table, context.spanID))
            }
            #expect(Telemetry.isEnabled(QueryB.self))
            Telemetry.emit(QueryB.self) {
                (.init(duration: .milliseconds(3), rows: 7), .init(table: "users"))
            }
            #expect(seen.count == 1)
            #expect(seen.all.first?.0 == 7)
            #expect(seen.all.first?.1 == "users")
            token.detach()
            Telemetry.emit(QueryB.self) { (.init(duration: .zero, rows: 1), .init(table: "x")) }
            #expect(seen.count == 1, "detached means detached")
            #expect(!Telemetry.isEnabled(QueryB.self))
        }

        @Test("a second handler with the same id on the same event is refused")
        func duplicateID() throws {
            let first = try Telemetry.attach(PingA.self, id: "same") { _, _, _ in }
            #expect(throws: AttachError.duplicateID("same", PingA.name)) {
                _ = try Telemetry.attach(PingA.self, id: "same") { _, _, _ in }
            }
            let other = try Telemetry.attach(PingA.self, id: "other") { _, _, _ in }
            _ = consume first
            _ = consume other
        }

        @Test("a token detaches when it goes out of scope; persist keeps it")
        func tokenLifetime() throws {
            let count = Atomic<Int>(0)
            do {
                let token = try Telemetry.attach(PingB.self, id: "scoped") { _, _, _ in
                    count.add(1, ordering: .relaxed)
                }
                Telemetry.emit(PingB.self)
                _ = consume token
            }
            Telemetry.emit(PingB.self)
            #expect(count.load(ordering: .relaxed) == 1)

            try Telemetry.attach(PingB.self, id: "kept") { _, _, _ in
                count.add(1, ordering: .relaxed)
            }
            .persist()
            Telemetry.emit(PingB.self)
            #expect(count.load(ordering: .relaxed) == 2)
        }

        @Test(
            "a handler that throws is detached, the others still run, and the failure is itself an event"
        )
        func failingHandler() throws {
            struct Boom: Error {}
            let good = Atomic<Int>(0)
            let failures = Recorder<String>()
            let failed = try Telemetry.attach(TelemetryHandlerFailed.self, id: "watch-ping-c") {
                _, metadata, _ in
                if metadata.event == PingC.name.description { failures.append(metadata.handler) }
            }
            let bad = try Telemetry.attach(PingC.self, id: "bad") { _, _, _ in throw Boom() }
            let fine = try Telemetry.attach(PingC.self, id: "fine") { _, _, _ in
                good.add(1, ordering: .relaxed)
            }

            Telemetry.emit(PingC.self)
            Telemetry.emit(PingC.self)
            #expect(good.load(ordering: .relaxed) == 2, "the other handler ran both times")
            #expect(failures.all == ["bad"], "detached after the first failure, reported once")
            _ = consume bad
            _ = consume fine
            _ = consume failed
        }

        @Test(
            "a handler that emits its own event is cut off at the depth cap instead of recursing forever"
        )
        func depthCap() throws {
            let depth = Atomic<Int>(0)
            let token = try Telemetry.attach(PingD.self, id: "recursive") { _, _, _ in
                depth.add(1, ordering: .relaxed)
                Telemetry.emit(PingD.self)
            }
            Telemetry.emit(PingD.self)
            #expect(depth.load(ordering: .relaxed) == 8)
            _ = consume token
        }

        @Test(
            "once detach returns, the handler is never called again — even by emits already in flight"
        )
        func detachGuarantee() async throws {
            for _ in 0..<50 {
                let state = RaceState()
                let token = try Telemetry.attach(PingE.self, id: "racy") { _, _, _ in
                    state.calls.add(1, ordering: .relaxed)
                    if state.detached.load(ordering: .sequentiallyConsistent) {
                        state.lateCalls.add(1, ordering: .relaxed)
                    }
                }
                // Emitters on their own threads: busy loops on the cooperative
                // pool took every pool thread of a 2-core runner, and this task
                // — the one that detaches — never ran again.
                async let emitters: Void = onThreads(4) { _ in
                    while !state.stop.load(ordering: .relaxed) {
                        Telemetry.emit(PingE.self)
                    }
                }
                while state.calls.load(ordering: .relaxed) < 10 { await Task.yield() }
                token.detach()
                state.detached.store(true, ordering: .sequentiallyConsistent)
                try await Task.sleep(for: .milliseconds(2))
                state.stop.store(true, ordering: .relaxed)
                await emitters
                #expect(state.lateCalls.load(ordering: .relaxed) == 0)
            }
        }
    }

}

extension CoreTests {
    @Suite("Erased handlers")
    struct ErasedTests {
        @Test("a prefix sees every event beneath it, by visitor, and nothing beside it")
        func prefix() throws {
            let seen = Recorder<String>()
            let token = try Telemetry.attach(prefix: "erasedtest.db", id: "log") { event in
                var fields: [String] = []
                event.forEachMeasurement { name, value in
                    fields.append("\(name)=\(value.telemetryDescription)")
                }
                event.forEachMetadata { name, value in
                    fields.append("\(name)=\(value.telemetryDescription)")
                }
                seen.append("\(event.name) " + fields.joined(separator: " "))
            }
            Telemetry.emit(ErasedOne.self) {
                (.init(duration: .seconds(1), rows: 3), .init(table: "users"))
            }
            Telemetry.emit(ErasedOther.self)
            #expect(seen.all == ["erasedtest.db.query duration=1.0 seconds rows=3 table=users"])
            _ = consume token
        }

        @Test("an erased prefix enables the fast path for events that have no typed handler")
        func enablesFastPath() throws {
            let token = try Telemetry.attach(prefix: "erasedtest.enable", id: "x") { _ in }
            #expect(Telemetry.isEnabled(ErasedOther.self), "the erased check is global, by design")
            _ = consume token
        }
    }

}

extension CoreTests {
    @Suite("Spans")
    struct SpanTests {
        struct Failure: Error {}

        @Test("unobserved, the body runs directly and the metadata is never built")
        func unobserved() throws {
            let built = Atomic<Int>(0)
            func metadata() -> LoadMetadata {
                built.add(1, ordering: .relaxed)
                return LoadMetadata(key: "k")
            }
            let result = Telemetry.span(Load.self, metadata: metadata()) { span in
                #expect(span.spanID == nil)
                return 42
            }
            #expect(result == 42)
            #expect(built.load(ordering: .relaxed) == 0)
        }

        @Test("start, then stop with the duration and the body's stop metadata")
        func stop() throws {
            let starts = Recorder<String>()
            let stops = Recorder<(String, Int, Duration)>()
            let a = try Telemetry.attach(Load.Start.self, id: "t") { _, metadata, _ in
                starts.append(metadata.key)
            }
            let b = try Telemetry.attach(Load.Stop.self, id: "t") { measurements, metadata, _ in
                stops.append((metadata.key, metadata.hits, measurements.duration))
            }
            let value = Telemetry.span(Load.self, metadata: .init(key: "users")) { span in
                span.stopMetadata.hits = 3
                return "done"
            }
            #expect(value == "done")
            #expect(starts.all == ["users"])
            #expect(stops.all.first?.0 == "users")
            #expect(stops.all.first?.1 == 3)
            #expect((stops.all.first?.2 ?? .zero) >= .zero)
            _ = consume a
            _ = consume b
        }

        @Test(
            "a throwing body emits exception with the error's type, and the typed error passes through"
        )
        func exception() throws {
            let failures = Recorder<String>()
            let token = try Telemetry.attach(Load.Exception.self, id: "t") { _, metadata, _ in
                failures.append(metadata.errorType)
            }
            #expect(throws: Failure.self) {
                try Telemetry.span(Load.self, metadata: .init(key: "k")) {
                    (_: inout SpanHandle<Load>) throws(Failure) in
                    throw Failure()
                }
            }
            #expect(failures.count == 1)
            #expect(failures.all.first?.hasSuffix("Failure") == true)
            _ = consume token
        }

        @Test(
            "an event inside a span carries its id; nested spans chain parents, across child tasks")
        func parentChain() async throws {
            let starts = Recorder<(TelemetrySpanID?, TelemetrySpanID?)>()
            let token = try Telemetry.attach(Load.Start.self, id: "chain") { _, _, context in
                starts.append((context.spanID, context.serviceContext?.telemetrySpan?.parentSpanID))
            }
            let outer = try await Telemetry.span(Load.self, metadata: .init(key: "outer")) {
                outer in
                let outerID = outer.spanID
                async let inner: TelemetrySpanID? = Telemetry.span(
                    Load.self, metadata: .init(key: "inner")
                ) { inner in
                    inner.spanID
                }
                _ = await inner
                return outerID
            }
            let recorded = starts.all
            #expect(recorded.count == 2)
            let outerStart = recorded.first { $0.1 == nil }
            let innerStart = recorded.first { $0.1 != nil }
            #expect(outerStart?.0 == outer)
            #expect(
                innerStart?.1 == outer,
                "the inner span's parent is the outer span, across the child task")
            _ = consume token
        }

        /// An observer that counts, and puts a marker in the context.
        struct MarkerKey: ServiceContextKey { typealias Value = String }
        struct CountingObserver: SpanObserver {
            let events: Recorder<String>
            func start(_ span: borrowing SpanStart, context: inout ServiceContext) -> String {
                context[MarkerKey.self] = "observed-\(span.name)"
                events.append("start")
                return "state"
            }
            func stop(_ span: borrowing SpanStop, state: consuming String) {
                var hits = ""
                span.forEachMetadata { name, value in
                    if name == "hits" { hits = value.telemetryDescription }
                }
                events.append("stop \(state) hits=\(hits)")
            }
            func exception(_ span: borrowing SpanFailure, state: consuming String) {
                events.append("exception \(state)")
            }
        }

        @Test("an observer carries state from start to stop, and its context reaches the body")
        func observer() throws {
            let events = Recorder<String>()
            let token = try Telemetry.observeSpans(
                prefix: "test.load", id: "count", CountingObserver(events: events))
            let marker = Telemetry.span(Load.self, metadata: .init(key: "k")) { span in
                span.stopMetadata.hits = 2
                return ServiceContext.current?[MarkerKey.self]
            }
            #expect(marker == "observed-test.load")
            #expect(events.all == ["start", "stop state hits=2"])
            _ = try? Telemetry.span(Load.self, metadata: .init(key: "k")) {
                (_: inout SpanHandle<Load>) throws(Failure) in
                throw Failure()
            }
            #expect(events.all.last == "exception state")
            _ = consume token
        }
    }
}

extension CoreTests {
    @Suite("Stress")
    struct StressTests {
        /// 16 emitters and 4 workers attaching and detaching typed handlers,
        /// erased handlers, and span observers, all at once, on dedicated
        /// threads — busy loops on the cooperative pool would starve every other
        /// suite's timers for the length of the run. Half a second by default;
        /// the CI ThreadSanitizer job sets `FLIGHT_TELEMETRY_STRESS_SECONDS=5`.
        @Test("emit, attach, and detach concurrently without a race or a late call")
        func stress() async throws {
            let seconds = Double(Environment.value("FLIGHT_TELEMETRY_STRESS_SECONDS") ?? "") ?? 0.5
            let state = RaceState()
            let deadline = ContinuousClock.now + .seconds(seconds)
            await onThreads(20) { index in
                guard index >= 16 else {
                    while ContinuousClock.now < deadline {
                        Telemetry.emit(PingStress.self)
                        Telemetry.span(Load.self, metadata: .init(key: "s")) { span in
                            span.stopMetadata.hits += 1
                        }
                    }
                    return
                }
                let worker = index - 16
                var round = 0
                while ContinuousClock.now < deadline {
                    round += 1
                    let flag = Flag()
                    do {
                        let typed = try Telemetry.attach(PingStress.self, id: "w\(worker)") {
                            _, _, _ in
                            if flag.value.load(ordering: .sequentiallyConsistent) {
                                state.lateCalls.add(1, ordering: .relaxed)
                            }
                            state.calls.add(1, ordering: .relaxed)
                        }
                        let erased = try Telemetry.attach(prefix: "test", id: "w\(worker)-\(round)")
                        { event in
                            event.forEachMetadata { _, _ in }
                        }
                        let observer = try Telemetry.observeSpans(
                            prefix: "test.load", id: "w\(worker)-\(round)", StressObserver())
                        typed.detach()
                        flag.value.store(true, ordering: .sequentiallyConsistent)
                        _ = consume erased
                        _ = consume observer
                    } catch {
                        Issue.record("attach failed: \(error)")
                    }
                }
            }
            #expect(state.lateCalls.load(ordering: .relaxed) == 0)
            #expect(state.calls.load(ordering: .relaxed) > 0, "the handlers ran at all")
        }

        struct StressObserver: SpanObserver {
            func start(_ span: borrowing SpanStart, context: inout ServiceContext) -> Int { 1 }
            func stop(_ span: borrowing SpanStop, state: consuming Int) {}
            func exception(_ span: borrowing SpanFailure, state: consuming Int) {}
        }
    }
}
