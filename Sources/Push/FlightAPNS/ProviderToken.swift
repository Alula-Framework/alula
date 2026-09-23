import CoreMetrics
import Foundation
import JWTKit
import Synchronization

/// The claims of an APNs provider token: who is asking (`iss`, the team id)
/// and when it was minted (`iat`). Apple wants nothing else in the payload,
/// and `kid` in the header.
struct ProviderTokenClaims: JWTPayload {
    let iss: IssuerClaim
    let iat: IssuedAtClaim

    /// Signing only; nothing verifies these here.
    func verify(using algorithm: some JWTAlgorithm) async throws {}
}

/// Mints and caches the ES256 provider token every request carries.
///
/// Apple accepts a token for an hour and refuses one refreshed more often
/// than every twenty minutes, so one is reused for ``lifetime`` and then
/// replaced. A 403 `ExpiredProviderToken` from the gateway — a clock that
/// drifted, or a token that outlived a gateway restart — calls
/// ``invalidate()``, and the next request mints afresh.
///
/// A new `JWTKeyCollection` per mint rather than one for the process: the
/// collection is an actor, adding a key is `async`, and a mint happens
/// once per fifty minutes. Simpler than a one-time async setup guarded
/// against every caller.
final class ProviderTokenSource: Sendable {
    /// Well inside Apple's twenty-to-sixty-minute window.
    static let lifetime: Duration = .seconds(50 * 60)

    private struct Cached {
        let token: String
        let issuedAt: Date
    }

    private let keyID: String
    private let teamID: String
    private let privateKey: ES256PrivateKey
    private let now: @Sendable () -> Date
    private let cached = Mutex<Cached?>(nil)

    private let metrics: any MetricsFactory

    init(
        keyID: String, teamID: String, privateKey: ES256PrivateKey,
        now: @escaping @Sendable () -> Date, metrics: any MetricsFactory = MetricsSystem.factory
    ) {
        self.keyID = keyID
        self.teamID = teamID
        self.privateKey = privateKey
        self.now = now
        self.metrics = metrics
    }

    /// The current token, minting one when there is none or the cached one
    /// has reached its lifetime.
    func token() async throws -> String {
        let now = now()
        if let cached = cached.withLock({ $0 }),
            now.timeIntervalSince(cached.issuedAt) < Self.lifetime.timeIntervalValue
        {
            return cached.token
        }
        let collection = JWTKeyCollection()
        let kid = JWKIdentifier(string: keyID)
        await collection.add(ecdsa: privateKey, kid: kid)
        let token = try await collection.sign(
            ProviderTokenClaims(iss: IssuerClaim(value: teamID), iat: IssuedAtClaim(value: now)),
            kid: kid)
        cached.withLock { $0 = Cached(token: token, issuedAt: now) }
        Counter(label: APNSMetrics.providerTokensMinted, factory: metrics).increment()
        return token
    }

    /// Drops the cached token, so the next ``token()`` mints.
    func invalidate() {
        cached.withLock { $0 = nil }
    }
}

extension Duration {
    var timeIntervalValue: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
