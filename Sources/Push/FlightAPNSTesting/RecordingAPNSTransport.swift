import FlightAPNS
import Foundation
import Synchronization

/// An `APNSTransport` that records every request and answers from a script,
/// so a suite can assert what would have reached the gateway — headers,
/// topic, payload — with no network and no Apple account. Hand it to
/// `APNSClient(configuration:transport:)`.
///
/// Answers `200` with a fresh `apns-id` until told otherwise. ``respond(with:)``
/// queues answers in order; ``misbehave()`` makes every call throw, which
/// is what a dropped connection looks like.
public final class RecordingAPNSTransport: APNSTransport, Sendable {
    private struct State {
        var sent: [APNSRequest] = []
        var queued: [APNSRawResponse] = []
        var misbehaving = false
    }

    private let state = Mutex<State>(State())

    public init() {}

    public func post(_ request: APNSRequest) async throws -> APNSRawResponse {
        try state.withLock { state in
            state.sent.append(request)
            guard !state.misbehaving else {
                throw RecordingAPNSTransportError.misbehaving
            }
            if !state.queued.isEmpty {
                return state.queued.removeFirst()
            }
            return APNSRawResponse(
                status: 200, headers: ["apns-id": UUID().uuidString.lowercased()])
        }
    }

    // MARK: - Scripting

    /// Queues an answer for the next request; several calls answer in order.
    public func respond(with response: APNSRawResponse) {
        state.withLock { $0.queued.append(response) }
    }

    /// Queues a gateway refusal in the shape Apple sends: the status, a
    /// JSON body with `reason` (and `timestamp` for a 410), and an `apns-id`.
    public func refuse(
        status: Int, reason: String, timestamp: Date? = nil, apnsID: String = "refused"
    ) {
        var body = "{\"reason\":\"\(reason)\""
        if let timestamp {
            body += ",\"timestamp\":\(Int(timestamp.timeIntervalSince1970 * 1000))"
        }
        body += "}"
        respond(
            with: APNSRawResponse(
                status: status, headers: ["apns-id": apnsID], body: Data(body.utf8)))
    }

    /// From now on, every call throws.
    public func misbehave() {
        state.withLock { $0.misbehaving = true }
    }

    // MARK: - Inspection

    /// Every request, in order.
    public var sent: [APNSRequest] {
        state.withLock { $0.sent }
    }

    /// The last request's payload, decoded as JSON — for asserting on `aps`
    /// and the custom keys beside it.
    public func lastPayload() throws -> [String: Any] {
        guard let last = state.withLock({ $0.sent.last }) else { return [:] }
        return try JSONSerialization.jsonObject(with: last.body) as? [String: Any] ?? [:]
    }
}

public enum RecordingAPNSTransportError: Error, Sendable, CustomStringConvertible {
    case misbehaving

    public var description: String { "RecordingAPNSTransport is misbehaving: every call throws" }
}
