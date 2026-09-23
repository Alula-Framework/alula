import FlightTelemetry
import Testing

// The macros, compiled for real: the expansion tests pin the text, these
// prove the text type-checks and behaves like the hand-written fixtures.

@TelemetryEvent("macrotest.cache.hit")
enum CacheHit {}

@TelemetryEvent("macrotest.query")
public enum MacroQuery {
    public struct Measurements {
        public var duration: Duration
        public var rows: Int
    }
    public struct Metadata {
        public var table: String
        public var errorCode: Int? = nil
    }
}

enum CacheTier: String, TagValue { case memory, disk }

@TelemetrySpan("macrotest.fetch", kind: .client)
public enum Fetch {
    public struct Metadata {
        public var key: String
        var tier: CacheTier = .memory
    }
    public struct StopMetadata {
        public var bytes: Int = 0
        public var hit: Bool = false
    }
}

@TelemetrySpan("macrotest.bare")
enum Bare {}

@TelemetryFields
public struct SharedMetadata {
    public var requestID: String
    public var userURL: String
}

extension CoreTests {
    @Suite("Macro-declared events")
    struct MacroUsageTests {
        @Test("@TelemetryEvent: name, slot, conformance, and snake_cased field names")
        func event() throws {
            #expect(CacheHit.name == "macrotest.cache.hit")
            #expect(MacroQuery.Metadata.fieldName(for: \.errorCode) == "error_code")
            #expect(MacroQuery.Measurements.fieldName(for: \.rows) == "rows")
            #expect(SharedMetadata.fieldName(for: \.requestID) == "request_id")
            #expect(SharedMetadata.fieldName(for: \.userURL) == "user_url")

            let seen = Recorder<String>()
            let typed = try Telemetry.attach(MacroQuery.self, id: "t") {
                measurements, metadata, _ in
                seen.append("\(metadata.table):\(measurements.rows)")
            }
            let erased = try Telemetry.attach(prefix: "macrotest.query", id: "e") { event in
                var fields: [String] = []
                event.forEachMeasurement { name, _ in fields.append(name) }
                event.forEachMetadata { name, value in
                    fields.append("\(name)=\(value.telemetryDescription)")
                }
                seen.append(fields.joined(separator: ","))
            }
            Telemetry.emit(MacroQuery.self) {
                (.init(duration: .milliseconds(1), rows: 4), .init(table: "users"))
            }
            #expect(
                seen.all == ["users:4", "duration,rows,table=users"], "a nil optional is skipped")
            _ = consume typed
            _ = consume erased
        }

        @Test("@TelemetrySpan: phases, kind, and flattened stop and exception metadata")
        func span() throws {
            struct Miss: Error {}
            #expect(Fetch.kind == .client)
            #expect(Bare.kind == .internal)
            #expect(Fetch.Stop.name == "macrotest.fetch.stop")
            #expect(Fetch.Exception.Metadata.fieldName(for: \.errorType) == "error_type")

            let stops = Recorder<String>()
            let token = try Telemetry.attach(Fetch.Stop.self, id: "t") { _, metadata, _ in
                stops.append("\(metadata.key) \(metadata.tier) \(metadata.bytes) \(metadata.hit)")
            }
            let failures = Recorder<String>()
            let failed = try Telemetry.attach(Fetch.Exception.self, id: "t") { _, metadata, _ in
                failures.append(
                    "\(metadata.key) \(metadata.errorType.hasSuffix("Miss")) \(metadata.bytes)")
            }
            let size = Telemetry.span(Fetch.self, metadata: .init(key: "a")) { span in
                span.stopMetadata.bytes = 512
                span.stopMetadata.hit = true
                return 512
            }
            #expect(size == 512)
            #expect(stops.all == ["a memory 512 true"])

            #expect(throws: Miss.self) {
                try Telemetry.span(Fetch.self, metadata: .init(key: "b", tier: .disk)) {
                    (span: inout SpanHandle<Fetch>) throws(Miss) in
                    span.stopMetadata.bytes = 7
                    throw Miss()
                }
            }
            #expect(failures.all == ["b true 7"])

            Telemetry.span(Bare.self, metadata: .init()) { _ in }
            _ = consume token
            _ = consume failed
        }
    }
}
