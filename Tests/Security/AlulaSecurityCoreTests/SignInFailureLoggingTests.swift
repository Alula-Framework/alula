import AlulaWeb
import AlulaWebTesting
import Logging
import Synchronization
import Testing

@testable import AlulaSecurityCore

@Suite("A failed sign-in says why, in the log")
struct SignInFailureLoggingTests {
    final class Capture: Sendable {
        let entries = Mutex<[(Logger.Level, String, Logger.Metadata)]>([])
        var logger: Logger { Logger(label: "test") { _ in Handler(capture: self) } }

        struct Handler: LogHandler {
            let capture: Capture
            var metadata: Logger.Metadata = [:]
            var logLevel: Logger.Level = .trace
            subscript(metadataKey key: String) -> Logger.Metadata.Value? {
                get { metadata[key] }
                set { metadata[key] = newValue }
            }
            func log(
                level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
                source: String, file: String, function: String, line: UInt
            ) {
                capture.entries.withLock { $0.append((level, message.description, metadata ?? [:])) }
            }
        }
    }

    /// Refuses every sign-in the way a provider's callback would, with a
    /// reason that arrived in the URL.
    struct Refusing: SignInProvider {
        let reason: String
        func beginSignIn(_ context: RequestContext, returnTo: String?) async throws -> SignInStep { .form(SignInForm(fields: [])) }
        func completeSignIn(_ context: RequestContext) async throws -> SignInResult {
            throw OIDCSignInError.providerRefused(reason)
        }
        func beginSignOut(_ context: RequestContext) async throws -> SignOutStep { .done }
    }

    @Test("the reason is logged at info, sanitized, and the error still reaches the caller")
    func logged() async throws {
        let capture = Capture()
        var context = RequestContext.mock(method: .get, path: "/callback")
        context.logger = capture.logger
        await #expect(throws: OIDCSignInError.self) {
            _ = try await Refusing(reason: "access_denied\nforged: line").signIn(context)
        }
        let entry = try #require(capture.entries.withLock { $0 }.first { $0.1 == "sign-in failed" })
        #expect(entry.0 == .info)
        let reason = "\(entry.2["reason"] ?? "")"
        #expect(reason.contains("access_denied"))
        #expect(!reason.contains("\n"), "a newline from the URL must not split the log line")
        #expect("\(entry.2["provider"] ?? "")".contains("Refusing"))
    }
}
