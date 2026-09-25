import Foundation
import Logging
import Synchronization

/// Writes each log record as one JSON object on one line, for log pipelines
/// that parse rather than read.
///
/// ```json
/// {"level":"warning","label":"alula.queue","message":"job failed; will retry",
///  "attempt":"2","job-id":"…","timestamp":"2026-09-24T10:00:07.123Z"}
/// ```
///
/// Metadata keys sit beside `timestamp`, `level`, `label` and `message`, not
/// nested, so a pipeline can index `request-id` without knowing Alula. A
/// metadata key that collides with one of those four is prefixed `metadata.`.
/// Nested metadata (dictionaries, arrays) is written as JSON.
///
/// `Alula.run` installs it when `logging.format: json`. To install it
/// yourself: `LoggingSystem.bootstrap { JSONLogHandler(label: $0) }`.
public struct JSONLogHandler: LogHandler {
    public var logLevel: Logger.Level
    public var metadata: Logger.Metadata = [:]
    public var metadataProvider: Logger.MetadataProvider?
    public let label: String
    private let write: @Sendable (String) -> Void

    public init(
        label: String, level: Logger.Level = .info,
        metadataProvider: Logger.MetadataProvider? = LoggingSystem.metadataProvider
    ) {
        self.init(label: label, level: level, metadataProvider: metadataProvider, write: JSONLogHandler.standardOutput)
    }

    /// For tests and custom sinks: `write` receives each line, newline excluded.
    public init(
        label: String, level: Logger.Level = .info, metadataProvider: Logger.MetadataProvider? = nil,
        write: @escaping @Sendable (String) -> Void
    ) {
        self.label = label
        self.logLevel = level
        self.metadataProvider = metadataProvider
        self.write = write
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: LogEvent) {
        var merged = metadata
        if let provided = metadataProvider?.get() { merged.merge(provided) { _, new in new } }
        if let own = event.metadata { merged.merge(own) { _, new in new } }

        var object: [String: Any] = [
            "timestamp": Self.timestamp(),
            "level": event.level.rawValue,
            "label": label,
            "message": event.message.description,
        ]
        for (key, value) in merged {
            let name = object[key] == nil ? key : "metadata.\(key)"
            object[name] = Self.json(value)
        }
        if event.level >= .error {
            object["source"] = "\(event.file):\(event.line)"
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return }
        write(String(decoding: data, as: UTF8.self))
    }

    private static func json(_ value: Logger.Metadata.Value) -> Any {
        switch value {
        case .string(let string): string
        case .stringConvertible(let convertible): convertible.description
        case .array(let values): values.map(json)
        case .dictionary(let values): values.mapValues(json)
        }
    }

    private static func timestamp() -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(Date())
    }

    /// One line per `write`, never interleaved: records from concurrent tasks
    /// would otherwise splice together and fail to parse.
    private static let lock = Mutex(())
    static let standardOutput: @Sendable (String) -> Void = { line in
        let bytes = Array((line + "\n").utf8)
        lock.withLock { _ in
            bytes.withUnsafeBufferPointer { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Foundation.write(1, buffer.baseAddress! + offset, buffer.count - offset)
                    if written <= 0 { return }
                    offset += written
                }
            }
        }
    }
}

/// `logging.*`: how `Alula.run` sets up swift-log.
///
/// ```yaml
/// logging:
///   format: json     # json | text
///   level: info      # trace | debug | info | notice | warning | error | critical
/// ```
///
/// Applied only when either key is set. swift-log can be set up once per
/// process, so an application that calls `LoggingSystem.bootstrap` itself must
/// leave these unset.
public struct LoggingSettings: Sendable, Equatable {
    public enum Format: String, Sendable, Equatable {
        case json
        case text
    }
    public var format: Format
    public var level: Logger.Level

    public init(format: Format = .text, level: Logger.Level = .info) {
        self.format = format
        self.level = level
    }

    /// Nil when configuration says nothing about logging.
    public init?(configuration: Configuration) throws {
        let rawFormat = try configuration.getIfPresent("logging.format", as: String.self)
        let rawLevel = try configuration.getIfPresent("logging.level", as: String.self)
        guard rawFormat != nil || rawLevel != nil else { return nil }
        guard let format = Format(rawValue: (rawFormat ?? "text").lowercased()) else {
            throw LoggingSettingsError("logging.format must be json or text; it is \(rawFormat ?? "")")
        }
        guard let level = Logger.Level(rawValue: (rawLevel ?? "info").lowercased()) else {
            throw LoggingSettingsError(
                "logging.level must be one of trace, debug, info, notice, warning, error, critical; it is \(rawLevel ?? "")")
        }
        self.init(format: format, level: level)
    }

    /// Sets up swift-log for the whole process. Call once.
    public func bootstrap() {
        let level = self.level
        switch format {
        case .json:
            LoggingSystem.bootstrap { label in
                JSONLogHandler(label: label, level: level, metadataProvider: nil)
            }
        case .text:
            LoggingSystem.bootstrap { label in
                var handler = StreamLogHandler.standardOutput(label: label)
                handler.logLevel = level
                return handler
            }
        }
    }
}

struct LoggingSettingsError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension LoggingSettingsError: ModuleConfigurationError {}
