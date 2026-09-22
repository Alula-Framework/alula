# Flight Sign-in

Signing people in, through a seam that does not care who checks the
password. An application can start on its own accounts and move to
Keycloak, Auth0, Okta, Entra or any other OpenID Connect provider by
changing one line in its module list, with no change to its routes, its
controllers or its front end.

Two providers ship:

- **`PasswordSignIn`** checks a password against the application's own
  accounts, through a `CredentialStore` the application implements over
  whatever storage it has.
- **`OIDCSignIn`** sends the browser to an external provider and takes it
  back, by the authorization-code flow with PKCE.

Both produce a `Principal` with the same four standard claims: `email`,
`email_verified`, `name` and `preferred_username`. Everything downstream
reads those claims the same way whichever provider produced them, including
roles, the `.authenticated` lane, `requirePrincipal()` and the session.

## Adding this module

| | |
|---|---|
| **Trait** | `Security` |
| **Products** | `FlightSecurityCore` |
| **Module** | `FlightPasswordSignInModule.self` *or* `FlightOIDCSignInModule.self` |
| **Pulls in** | `FlightSecurityModule`, `FlightSessionsModule`; password also `FlightRateLimitModule` |

```swift
await Flight.run(
    configuration: try Configuration.load(),
    modules: [
        FlightWebModule<FlightTransport>.self,
        FlightPasswordSignInModule.self,        // ← the one line a switch changes
        AppModule.self,
    ],
    composedBy: flightComposeModules)
```

Both modules provide `signInProvider: any SignInProvider`. Listing both is
refused at build time, because a type with two providers is ambiguous. That's
the right answer to "which one signs people in?".

`FlightSecurityModule` no longer needs a bearer-token validator when
sessions are present. An application that signs browsers in and has no
bearer API lists no `FlightOIDCModule`. A bearer token presented to it
anyway is an invalid credential rather than silently ignored.

## The routes, written once

```swift
@Controller("/auth")
struct SignInController {
    @Inject var provider: any SignInProvider

    @GetRoute("/sign-in")
    func begin(_ context: RequestContext) async throws -> Response {
        try await provider.beginSignIn(context, returnTo: context.request.queryParam("return-to"))
            .response()
    }

    @PostRoute("/sign-in", pipelines: [.default, "csrf"])   // the password form posts here
    func submit(_ context: RequestContext) async throws -> Response {
        try await provider.signIn(context).response()
    }

    @GetRoute("/callback")                                  // an OIDC provider returns here
    func callback(_ context: RequestContext) async throws -> Response {
        try await provider.signIn(context).response()
    }

    @PostRoute("/sign-out", pipelines: [.default, "csrf"])
    func signOut(_ context: RequestContext) async throws -> Response {
        try await provider.signOut(context).response()
    }
}
```

`beginSignIn` answers one of two ways. **A form** is a `200` whose JSON
lists the fields to show, with the `autocomplete` tokens password managers
key on. **A redirect** is a `303` to the provider's own page. A front end
that asks first and handles both needs no change when the provider does.
That's the one place a switch would otherwise leak into the UI, so write
the front end that way from the start, even while the only provider is
local.

`signIn(_:)` finishes the sign-in and puts the principal in the session,
which regenerates the session id. `returnTo` must be a path on this site.
Anything else is dropped rather than followed, because a sign-in page that
redirects wherever a query string says is an open redirect.

Every route that changes state belongs on the `csrf` lane, including
sign-in. See *Guard sign-in too* in `Docs/web.md` for why.

## Password sign-in

### The credential store

The application's accounts stay the application's. `CredentialStore` asks
for two things only: find an account by what the user typed, and save a
stronger hash after a sign-in.

```swift
struct AccountCredentials: CredentialStore {
    let accounts: AccountRepository

    func credential(forIdentifier identifier: String) async throws -> StoredCredential? {
        guard let account = try await accounts.find(email: identifier) else { return nil }
        return StoredCredential(
            subject: account.id.uuidString,            // opaque, never the email
            passwordHash: account.passwordHash,
            roles: Set(account.roles),
            isDisabled: account.disabledAt != nil,
            email: account.email, emailVerified: account.emailVerifiedAt != nil,
            name: account.displayName)
    }

    func updatePasswordHash(_ hash: String, forSubject subject: String) async throws {
        try await accounts.setPasswordHash(hash, id: UUID(uuidString: subject)!)
    }
}
```

The identifier arrives trimmed and Unicode-normalized. Case-folding is the
store's decision, through a `citext` column, a lowered index, or exact
matching, because only the store knows whether "Ada" and "ada" are one
account. `InMemoryCredentialStore` exists for tests and prototypes.

Provide the store from one of your modules as
`let credentialStore: any CredentialStore`, and the password module takes it
by type.

### What the authenticator does for you

`PasswordAuthenticator` is the part that is short to write and easy to get
wrong. It does all of the following:

- **Throttles before hashing.** Per identifier and per client address,
  through the application's `RateLimiter`. The defaults are 10 attempts per
  identifier and 60 per address in 15 minutes. A refused attempt costs no
  Argon2 work, so the throttle also stops a flood of sign-ins from spending
  the server's CPU. A throttled attempt is a `429` with `Retry-After`.
- **Does the same work for an account that doesn't exist.** An unknown
  identifier is verified against a dummy hash, so response time doesn't
  reveal which accounts are real.
- **Gives one answer for every wrong guess.** An unknown account, an account
  with no password, and a wrong password are all `401 Invalid credentials`.
  A disabled account is reported, as a `403`, only after its password
  verifies.
- **Normalizes input.** Passwords are NFKC-normalized, as NIST SP 800-63B
  recommends, so the same password typed on two keyboards verifies. ASCII is
  unchanged, so older hashes still verify. Hash new passwords with
  `hashNewPassword(_:)` rather than the hasher directly, so they're
  normalized the same way.
- **Strengthens hashes over time.** A hash made under weaker parameters is
  replaced after a successful sign-in, the only moment the plaintext is
  available.
- **Fails closed.** If the credential store or the throttle is down,
  sign-in answers `503`. It doesn't let everyone in, and it doesn't
  tell everyone their password is wrong. The general `RateLimiting`
  middleware fails open. Sign-in is the one place that trade reverses,
  because the throttle is the brute-force defense.

`security.password.issuer` sets the `issuer` on principals the password
provider produces. It defaults to `local`.

## OIDC sign-in

```yaml
security:
  oidc:
    issuer: "https://keycloak.example.com/realms/main"
    client-id: "my-app"
    client-secret: "…"                          # omit for a public client
    redirect-uri: "https://app.example.com/auth/callback"
    post-logout-redirect-uri: "https://app.example.com/"
    sign-in-scopes: "openid profile email"       # the default
```

`OIDCSignIn` discovers the provider's endpoints and sends the browser to it
with a fresh `state`, `nonce` and PKCE challenge, all three kept in the
session. On the way back it matches `state`, which is single-use and expires
after ten minutes. It then exchanges the code, proving with the PKCE
verifier that it's the client that started. Finally it validates the ID
token exactly as a bearer token is validated, plus its `nonce`. Every
endpoint the discovery document names is held to the same transport policy
as the key fetch.

No tokens are kept. The ID token establishes who signed in, once, and the
session holds the principal, the same as for every other sign-in. Signing
out redirects to the provider's end-session endpoint when it has one.

`FlightOIDCSignInModule` doesn't validate bearer tokens. List
`FlightOIDCModule` beside it for an API that also accepts them. The two
share the one `security.oidc` block.

**Keycloak specifically** puts realm roles only in the access token by
default. Add a *User Realm Role* mapper to the client with **Add to ID
token** on, claim name `roles`. `CI/keycloak/flight-test-realm.json` is a
working example, and `CI/keycloak/start.sh` starts it for the integration
suite.

## Switching providers

The code change is one line in `modules:`, plus the `security.oidc` block.
The rest of a real switch is data, and it's cheap to prepare for from day
one:

- **Subjects.** `StoredCredential.subject` must be an opaque, stable id,
  never an email address. When you move to an identity provider, import
  each user with your old subject as an attribute, and map the provider's
  `sub` back to it. Every row keyed by user then survives the move.
- **Passwords.** Hashes are stored as standard Argon2id PHC strings, the
  most portable password-hash format there is. Where the provider's bulk
  import accepts them, users move without a reset. Check the provider's
  current import documentation before promising that. Where it doesn't,
  the provider can check passwords against your old store until each user
  next signs in, and then keep them. Keycloak's user-storage extension and
  Auth0's custom-database connections both work that way.
- **Claims.** Nothing changes. The provider emits the same four standard
  claims under the same names.
- **Front end.** Nothing changes, if it asks `beginSignIn` first and handles
  both answers.

## One-time links

The primitive under password reset, email verification and magic sign-in
links:

```swift
let tokens = OneTimeTokens(store: tokenStore)

// Issue — the raw token goes in the email and nowhere else.
let token = try await tokens.issue(
    for: account.subject, purpose: .passwordReset, lifetime: .seconds(3600),
    binding: account.passwordHash)

// Redeem — once.
let subject = try await tokens.redeem(token, purpose: .passwordReset) { subject in
    try await accounts.find(subject: subject)?.passwordHash
}
```

A token is 256 random bits, and the store keeps only its SHA-256, so a
leaked store or backup redeems nothing. Redeeming takes the record out of
the store in one atomic step, so two requests racing with one link get one
success. A token issued for one purpose is refused for any other.

`binding` is optional. It's any value the token should stop working once
that value changes. Bind a reset token to the current password hash, and
any password change, by this link or another way, voids every reset link
already sent. Every failure is the same `400`: unknown, used, expired,
wrong purpose, or stale binding.

`InMemoryOneTimeTokenStore` is for one replica. flight-data's Valkey store
shares tokens across replicas from 0.10.0.

## Signing out everywhere

A session knows whose it is. `signIn` records the subject as its owner,
so `SessionRuntime.revokeSessions(ownedBy:keeping:)` can end every other
session one person has after a password change, or all of them when an
account is disabled. `Docs/sessions.md` has the details, including which
stores support it.

## Not yet here

Registration, password-reset and email-verification *flows*, a user
directory, and MFA. The primitives above are what those flows are built
from. The flows themselves come next, following the same rule: a local
implementation, and an external one where the provider hosts the flow.

Issuing tokens for other applications is deliberately not planned. The moment
other services need to trust your tokens, you're running an identity
provider, and that's the point to switch to one.
