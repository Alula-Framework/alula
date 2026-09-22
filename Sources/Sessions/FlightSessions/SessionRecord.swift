import Foundation

/// What a store holds under one id: the values, the flash written by the
/// request that saved it, and the two dates that bound its life.
///
/// One JSON blob per session. Values are already `Data` — each was encoded
/// when `Session.set` was called — so the record format is the framework's
/// and never depends on an application's date strategy or key convention.
public struct SessionRecord: Codable, Sendable, Equatable {
    /// Each value, already encoded by `Session.set`.
    public var values: [String: Data]

    /// Written during the request that saved this record; readable by the
    /// next one, and cleared when that one saves.
    public var flash: [String: Data]

    public var createdAt: Date

    /// When the store may drop it. Stores with native expiry (`SET … PX`)
    /// enforce it themselves; the middleware also reads it, to decide when a
    /// sliding renewal is due.
    public var expiresAt: Date

    /// Whose session this is — an opaque id the application gave it, the
    /// signed-in principal's subject when FlightSecurityCore signs someone
    /// in. What lets every session of one person be found and ended at once
    /// (``OwnerIndexedSessionStore``). Nil for an anonymous session, and
    /// omitted from the encoding then, so a record without an owner encodes
    /// exactly as it did before owners existed.
    public var owner: String?

    public init(
        values: [String: Data] = [:],
        flash: [String: Data] = [:],
        createdAt: Date,
        expiresAt: Date,
        owner: String? = nil
    ) {
        self.values = values
        self.flash = flash
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.owner = owner
    }

    /// The bytes a store is handed.
    public func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    /// The bytes a store handed back.
    public init(decoding data: Data) throws {
        self = try Self.decoder.decode(SessionRecord.self, from: data)
    }

    // One pair for the process. Dates as milliseconds since 1970 — a fixed
    // strategy, so a record written by one replica reads on another whatever
    // either application's `web.json.date-strategy` says. Sorted keys so
    // that equal records encode to equal bytes, which is what lets "set to
    // what was already there" cost no write.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
