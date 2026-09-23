# Flight APNS

An Apple Push Notification service client: one call, one delivery attempt,
a typed answer. It mints and reuses the ES256 provider token, speaks HTTP/2
to the gateway, and turns Apple's reply into a receipt or an error that says
the one thing an application must act on — whether the device token is dead.

Hand-rolled over AsyncHTTPClient and JWTKit rather than wrapped around a
push library, for the reason the JWKS fetch in Security Core is: Flight
owns orchestration, the cryptography is JWTKit's, and the HTTP is a couple
of hundred lines that the hermetic test seam needs to own anyway.

## Adding this module

| | |
|---|---|
| **Trait** | `APNS` — brings JWTKit and AsyncHTTPClient, the same two packages `Security` brings, and nothing from `Web` |
| **Products** | `FlightAPNS`; `FlightAPNSTesting` for tests |
| **Module** | `FlightAPNSModule.self` |

```swift
// Package.swift
dependencies: [
    .package(
        url: "https://github.com/Flight-Framework/flight.git",
        from: "0.32.0", traits: ["APNS"]),          // add "Web" if it also serves HTTP
],
targets: [
    .executableTarget(
        name: "App",
        dependencies: [
            .product(name: "FlightCore", package: "flight"),
            .product(name: "FlightAPNS", package: "flight"),
        ],
        plugins: [.plugin(name: "FlightRegistrationPlugin", package: "flight")]
    )
]
```

```swift
// Sources/App/Main.swift
import FlightAPNS
import FlightCore

@main
struct Main {
    static func main() async {
        await Flight.run(
            configuration: try Configuration.load(),
            modules: [FlightAPNSModule.self, AppModule.self],
            composedBy: flightComposeModules)
    }
}
```

```yaml
# flight.yaml
apns:
  key-id: ABC123DEFG
  team-id: DEF456GHIJ
  private-key-path: /run/secrets/apns.p8     # or `private-key`, the PEM itself — FLIGHT_APNS_PRIVATE_KEY
  topic: com.example.app
  environment: sandbox                       # production is the default
```

Not gated on `Web`: a worker that sends pushes from a `@Scheduler` job pays
for no HTTP server.

## Quick start

```swift
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
                try await devices.forget(device)      // it died, and has not registered again since
            }
        }
    }
}
```

`APNSNotification` carries the `aps` dictionary, your own keys beside it,
and the headers that shape delivery:

```swift
struct Payload: Encodable { let conversation: String }

var notification = APNSNotification(
    aps: APS(alert: APS.Alert(title: "Ada", body: "are you there?"), sound: "default",
             threadID: "conv-42", mutableContent: true),
    custom: Payload(conversation: "42"))
notification.collapseID = "conv-42"                 // newest wins on the device
notification.expiration = .now.addingTimeInterval(600)
try await apns.send(notification, to: token)

try await apns.send(.background, to: token)       // content-available: 1, priority 5
```

`Custom` is encoded as top-level siblings of `aps`, which is the shape Apple
reads custom data in, so it must encode as an object. A `Custom` that
encodes as an array or a scalar is refused before any request, as is a
payload over the type's ceiling (4 KB; 5 KB for `voip`).

### Push types and topics

`pushType` sets the `apns-push-type` header Apple requires and, for the
types that need one, appends the suffix to the configured topic:

| type | topic sent |
|---|---|
| `alert`, `background` | the bundle id |
| `voip` | `<bundle>.voip` |
| `complication` | `<bundle>.complication` |
| `fileprovider` | `<bundle>.pushkit.fileprovider` |
| `location` | `<bundle>.location-query` |
| `liveactivity` | `<bundle>.push-type.liveactivity` |
| `pushtotalk` | `<bundle>.voip-ptt` |
| `widgets` | `<bundle>.push-type.widgets` |
| `mdm` | whatever `topic` you set — the push certificate's |

A notification's own `topic` is sent as given, suffix and all.

### What the answer means

| | |
|---|---|
| `APNSReceipt.apnsID` | The `apns-id`, yours or the gateway's. What to quote to Apple |
| `APNSError.reason` | Apple's reason, as an enum; unknown ones keep `rawReason` |
| `APNSError.shouldForgetDeviceToken(registeredAt:)` | Delete the stored token? Only on a `410`, and only if the device hasn't registered again since Apple stopped accepting the token |
| `APNSError.deviceTokenProblem` | `.inactive(since:)` (`410 Unregistered`, `ExpiredToken`), `.rejected` (`BadDeviceToken`), `.wrongTopic` (`DeviceTokenNotForTopic`) |
| `APNSError.timestamp` | On a `410`: when the token stopped being valid |
| `APNSError.retryAdvice` | `.throttled` (429: slow the whole stream), `.backOff` (5xx: exponential backoff), `.reconnect` (the connection failed), or `.never` |

**Keep when each token was registered.** A device that reinstalls, or has
its token rotated, registers again. A `410` for a push sent before that can
arrive after it, and deleting on it would remove a live token. So store
`registeredAt` with each token, updated every time the device reports it.
`shouldForgetDeviceToken` compares it with the `410`'s timestamp.

**Don't delete on `BadDeviceToken` or `DeviceTokenNotForTopic`.** Every
token returns those when the environment or the topic is misconfigured, for
example a sandbox token sent to production, or the wrong bundle id. An
application that deleted on them would lose every device it knows about to
one configuration mistake. When they appear for every token at once, fix
the configuration. When one token fails this way while others to the same
topic succeed, that one token is bad, and forgetting it is right.
`deviceTokenIsInvalid` treated all four reasons alike, so it's deprecated
in favour of the two above.

`flight_apns_sends` counts every send by `outcome`, which is `delivered`
or Apple's reason string. `flight_apns_provider_tokens_minted` counts each
provider token signed. Apple refuses updates more often than every 20
minutes, so a rising rate there warns before `TooManyProviderTokenUpdates`
does. `APNSClient(metrics:)` takes a factory for tests.

The one retry the client performs itself is the one the protocol asks for:
a `403 ExpiredProviderToken` mints a fresh token and sends once more. Every
other retry — and every fan-out — is the application's, because the right
policy depends on what the pushes are.

## Configuration reference

All keys under `apns.` (env-var form `FLIGHT_APNS_*`), kebab-case.

| key | required | default | meaning |
|---|---|---|---|
| `key-id` | yes | — | The ten-character id of the signing key |
| `team-id` | yes | — | The ten-character team id |
| `private-key` | one of the two | — | The `.p8` contents, PEM |
| `private-key-path` | one of the two | — | A path to the `.p8`, read once at composition |
| `topic` | yes | — | The bundle identifier |
| `environment` | no | `production` | `production` or `sandbox` |
| `request-timeout` | no | `10s` | One request, connection included |

Missing keys, an unparseable key, both key sources at once, and an unknown
environment fail at composition. `APNSConfiguration`'s description names
everything but the key.

### The provider token

Minted with the `.p8` key: `kid` in the header, `iss` (team id) and `iat`
in the claims, ES256. Apple accepts one for an hour and refuses a provider
that refreshes more often than every twenty minutes, so the client reuses
each token for fifty minutes. A `403 ExpiredProviderToken` — a drifted
clock, a gateway restart — invalidates it early.

### The connection

AsyncHTTPClient's shared client, which negotiates HTTP/2 over TLS by ALPN
and pools the connection between pushes. A client of the module's own,
with tuned idle timeouts, would give `FlightAPNSModule` a `service`;
nothing has needed it.

## Testing

`RecordingAPNSTransport` from `FlightAPNSTesting` stands in for the gateway:
it records every request and answers from a script.

```swift
let gateway = RecordingAPNSTransport()
let apns = APNSClient(configuration: configuration, transport: gateway)
let reminders = Reminders(apns: apns, devices: fakeDevices)

try await reminders.remind(ada)
#expect(gateway.sent.count == 2)
#expect(gateway.sent[0].header("apns-topic") == "com.example.app")
#expect((try gateway.lastPayload()["aps"] as? [String: Any])?["badge"] as? Int == 1)

gateway.refuse(status: 410, reason: "Unregistered", timestamp: .now)
try await reminders.remind(ada)
#expect(fakeDevices.forgotten == [deadToken])
```

`APNSClient` takes a clock, so provider-token reuse and refresh are tested
without waiting fifty minutes. No test in this package talks to Apple: a
fixture gives everything a sandbox round-trip would, and a credential in CI
is a cost with no payoff.

## Deliberately not here

- **A queue, batching, backoff.** A `@Scheduler` job or the application's
  own worker owns retry and fan-out; the client is one request with a typed
  answer. DECISIONS.md D32.
- **Certificate authentication.** Token auth is what Apple recommends, one
  key serves every app on the team, and it needs no TLS client-certificate
  plumbing.
- **A device-token registry.** Which tokens belong to which account is
  application data.
- **Other push services.** `FlightAPNS` is named for what it is; an FCM
  client would be a sibling target, not a generalisation of this one.
