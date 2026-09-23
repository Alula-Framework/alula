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
struct DeviceRegistration: Sendable {
    let token: DeviceToken
    /// Updated every time the device reports this token.
    let registeredAt: Date
}
struct DeviceRepository: Sendable {
    func registrations(for account: Account) async throws -> [DeviceRegistration] { [] }
    func forget(_ device: DeviceRegistration) async throws {}
}
let logger = Logger(label: "snippet")
// snippet.show

@Service
struct Reminders {
    @Inject var apns: APNSClient
    @Inject var devices: DeviceRepository

    func remind(_ account: Account) async throws {
        for device in try await devices.registrations(for: account) {
            do {
                let receipt = try await apns.send(
                    .alert(title: "Standup", body: "in 5 minutes", badge: 1), to: device.token)
                logger.debug("sent", metadata: ["apns-id": "\(receipt.apnsID)"])
            } catch let error as APNSError
                where error.shouldForgetDeviceToken(registeredAt: device.registeredAt)
            {
                try await devices.forget(device)  // it died, and has not registered again since
            }
        }
    }
}

func apnsShapes(configuration: Configuration, apns: APNSClient, token: DeviceToken) async throws {
    do {
        _ = try await apns.send(.background, to: token)
    } catch let error as APNSError {
        switch error.retryAdvice {
        case .throttled, .backOff, .reconnect: break  // the application's retry policy
        case .never: break
        }
        if case .inactive(let since) = error.deviceTokenProblem { _ = since }
    }
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
