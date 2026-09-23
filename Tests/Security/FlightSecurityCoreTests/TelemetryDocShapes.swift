// Doc examples that capture telemetry, compiled. They live here rather than
// in Snippets/ because capture is swift-telemetry's TelemetryTesting, which
// only a test target links. `Docs/testing.md`, `Docs/sign-in.md`.

import FlightSecurityCore
import TelemetryTesting

func signInCaptureShapes(authenticator: PasswordAuthenticator) async {
    let attempts = await TelemetryTest.capture(SignInEvents.Attempt.self) {
        _ = try? await authenticator.authenticate(
            identifier: "ada", password: "wrong", clientAddress: nil)
    }
    precondition(attempts.map(\.metadata.outcome) == ["invalid_credentials"])
}
