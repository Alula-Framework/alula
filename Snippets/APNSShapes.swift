// Every shape Docs/apns.md claims, compiled.
//
// A doc example that does not compile costs a reader the time to find out.
// This builds as part of `swift build`, so a rename that invalidates the
// prose breaks the build.

import FlightAPNS
import FlightAPNSTesting
import FlightCore
import Foundation
import Logging

// snippet.hide
struct Account: Sendable {}
struct DeviceRepository: Sendable {
    func tokens(for account: Account) async throws -> [DeviceToken] { [] }
    func forget(_ token: DeviceToken) async throws {}
}
let logger = Logger(label: "snippet")
// snippet.show

@Service
struct Reminders {
    @Inject var apns: APNSClient
    @Inject var devices: DeviceRepository

    func remind(_ account: Account) async throws {
        for token in try await devices.tokens(for: account) {
            do {
                let receipt = try await apns.send(
                    .alert(title: "Standup", body: "in 5 minutes", badge: 1), to: token)
                logger.debug("sent", metadata: ["apns-id": "\(receipt.apnsID)"])
            } catch let error as APNSError where error.deviceTokenIsInvalid {
                try await devices.forget(token)
            }
        }
    }
}

func apnsShapes(configuration: Configuration, apns: APNSClient, token: DeviceToken) async throws {
    struct Payload: Encodable { let conversation: String }

    var notification = APNSNotification(
        aps: APS(
            alert: APS.Alert(title: "Ada", body: "are you there?"), sound: "default",
            mutableContent: true, threadID: "conv-42"),
        custom: Payload(conversation: "42"))
    notification.collapseID = "conv-42"
    notification.expiration = Date().addingTimeInterval(600)
    _ = try await apns.send(notification, to: token)
    _ = try await apns.send(.background, to: token)

    // The module, built the way the composition root builds it.
    let module = try FlightAPNSModule(configuration: configuration)
    _ = module.client.configuration.environment

    // Tests: the gateway, replaced by a recorder.
    let gateway = RecordingAPNSTransport()
    let client = APNSClient(configuration: module.settings, transport: gateway)
    _ = try await client.send(.alert(body: "hi"), to: token)
    _ = gateway.sent.last?.header("apns-topic")
    _ = try gateway.lastPayload()["aps"]
    gateway.refuse(status: 410, reason: "Unregistered", timestamp: Date())
}
