import AlulaCore

/// One way a bearer token can be authenticated, and how to tell a token is
/// meant for it.
///
/// Strategies compose instead of competing for the application's one
/// `any TokenValidator`: any module contributes `tokenStrategies:
/// [TokenStrategy]`, `AlulaSecurityModule` collects them all, and each
/// incoming token goes to the strategy that recognizes it. A token no
/// strategy recognizes goes to the application's `any TokenValidator` when
/// there is one, which is how API keys for automation sit beside
/// `AlulaOIDCModule`'s tokens for people:
///
/// ```swift
/// modules: [
///     AlulaOIDCModule.self,     // any TokenValidator: everything else
///     AlulaAPIKeyModule.self,   // tokenStrategies: tokens starting "sk_"
///     AppModule.self,           // provides `any APIKeyStore`
/// ]
/// ```
///
/// Recognition must not overlap. A token two strategies both recognize is
/// refused, rather than going to whichever module happened to be listed
/// first, and the log names both.
public struct TokenStrategy: Sendable {
    public let name: String
    public let validator: any TokenValidator
    let recognizes: @Sendable (String) -> Bool

    /// - Parameters:
    ///   - name: What the log calls it.
    ///   - recognizes: Whether a token is this strategy's to check. Cheap and
    ///     syntactic, such as a prefix: it runs on every bearer token.
    ///   - validator: What checks a token it recognizes.
    public init(
        _ name: String, recognizes: @escaping @Sendable (String) -> Bool,
        validator: any TokenValidator
    ) {
        self.name = name
        self.recognizes = recognizes
        self.validator = validator
    }
}

/// Sends each token to the one strategy that recognizes it, or to `fallback`.
///
/// Built by `AlulaSecurityModule` from the strategies modules contribute; use
/// it directly only when wiring authentication by hand.
public struct CompositeTokenValidator: TokenValidator {
    public let strategies: [TokenStrategy]
    public let fallback: (any TokenValidator)?

    public init(strategies: [TokenStrategy], fallback: (any TokenValidator)?) {
        self.strategies = strategies
        self.fallback = fallback
    }

    public func validate(_ token: String) async throws -> Principal {
        let matching = strategies.filter { $0.recognizes(token) }
        switch matching.count {
        case 1:
            return try await matching[0].validator.validate(token)
        case 0:
            guard let fallback else {
                throw TokenValidationError(
                    kind: .malformedToken, reason: "no authentication strategy recognizes the token"
                )
            }
            return try await fallback.validate(token)
        default:
            throw TokenValidationError(
                kind: .malformedToken,
                reason: "token recognized by more than one strategy: "
                    + matching.map(\.name).joined(separator: ", "))
        }
    }
}

/// API keys as a ``TokenStrategy``, beside whatever validator the application
/// has.
///
/// Takes the application's `any APIKeyStore`. Reads
/// `security.api-keys.prefix` (default `sk`) and `security.api-keys.issuer`
/// (default `local`).
public struct AlulaAPIKeyModule: AlulaModule {
    public static var dependencies: [any AlulaModule.Type] { [AlulaSecurityModule.self] }

    public let tokenStrategies: [TokenStrategy]

    public init(configuration: Configuration, store: any APIKeyStore) throws {
        let prefix =
            try configuration.getIfPresent("security.api-keys.prefix", as: String.self) ?? "sk"
        guard APIKeys.isValidPrefix(prefix) else {
            throw APIKeyConfigurationError(prefix: prefix)
        }
        let issuer =
            try configuration.getIfPresent("security.api-keys.issuer", as: String.self) ?? "local"
        let validator = APIKeyValidator(store: store, prefix: prefix, issuer: issuer)
        self.tokenStrategies = [validator.strategy]
    }

    public init() {
        preconditionFailure(
            "AlulaAPIKeyModule takes the application's `any APIKeyStore` in "
                + "init(configuration:store:). Pass `composedBy: alulaComposeModules` to Alula.run."
        )
    }
}

struct APIKeyConfigurationError: Error, CustomStringConvertible {
    let prefix: String
    var description: String {
        "security.api-keys.prefix must be letters and digits only (got '\(prefix)')"
    }
}
