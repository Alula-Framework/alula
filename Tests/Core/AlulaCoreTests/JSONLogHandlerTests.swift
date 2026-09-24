import Foundation
import Logging
import Synchronization
import Testing

@testable import AlulaCore

@Suite("JSON log handler")
struct JSONLogHandlerTests {
    final class Lines: Sendable {
        let all = Mutex<[String]>([])
        func append(_ line: String) { all.withLock { $0.append(line) } }
        var parsed: [[String: Any]] {
            all.withLock { $0 }.compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }
    }

    private func logger(_ lines: Lines, level: Logger.Level = .info) -> Logger {
        Logger(label: "test.label") { label in
            JSONLogHandler(label: label, level: level, write: { lines.append($0) })
        }
    }

    @Test("one parseable object per record: fields, flattened metadata, no newlines")
    func shape() throws {
        let lines = Lines()
        var logger = logger(lines)
        logger[metadataKey: "request-id"] = "r-1"
        logger.info(
            "a \"quoted\"\nmessage",
            metadata: ["attempt": "2", "nested": ["a": "b"], "list": ["x", "y"]])

        let raw = try #require(lines.all.withLock { $0.first })
        #expect(!raw.contains("\n"))
        let record = try #require(lines.parsed.first)
        #expect(record["level"] as? String == "info")
        #expect(record["label"] as? String == "test.label")
        #expect(record["message"] as? String == "a \"quoted\"\nmessage")
        #expect(record["request-id"] as? String == "r-1")
        #expect(record["attempt"] as? String == "2")
        #expect((record["nested"] as? [String: String]) == ["a": "b"])
        #expect((record["list"] as? [String]) == ["x", "y"])
        let timestamp = try #require(record["timestamp"] as? String)
        #expect(timestamp.hasSuffix("Z") && timestamp.contains("T"))
        #expect(record["source"] == nil, "only errors carry their source line")
    }

    @Test("a metadata key named like a field does not overwrite it")
    func collisions() throws {
        let lines = Lines()
        logger(lines).info("real", metadata: ["message": "impostor", "level": "fake"])
        let record = try #require(lines.parsed.first)
        #expect(record["message"] as? String == "real")
        #expect(record["metadata.message"] as? String == "impostor")
        #expect(record["level"] as? String == "info")
    }

    @Test("below the level, nothing is written; errors say where they came from")
    func levels() throws {
        let lines = Lines()
        let logger = logger(lines, level: .warning)
        logger.info("quiet")
        logger.error("loud")
        let records = lines.parsed
        #expect(records.map { $0["message"] as? String } == ["loud"])
        #expect((records.first?["source"] as? String)?.contains("JSONLogHandlerTests.swift") == true)
    }

    @Test("logging.* is read only when set, and refuses what it does not know")
    func settings() throws {
        #expect(try LoggingSettings(configuration: Configuration()) == nil)
        #expect(
            try LoggingSettings(configuration: Configuration(values: ["logging.format": "JSON"]))
                == LoggingSettings(format: .json, level: .info))
        #expect(
            try LoggingSettings(configuration: Configuration(values: ["logging.level": "debug"]))
                == LoggingSettings(format: .text, level: .debug))
        #expect(throws: (any Error).self) {
            try LoggingSettings(configuration: Configuration(values: ["logging.format": "xml"]))
        }
        #expect(throws: (any Error).self) {
            try LoggingSettings(configuration: Configuration(values: ["logging.level": "loud"]))
        }
    }
}
