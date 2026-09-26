import AlulaWeb

protocol CredentialStore: Sendable {}
struct DatabaseCredentials: CredentialStore {}
struct DemoCredentials: CredentialStore {}

struct AccountsModule: AlulaModule {
    let credentialStore: any CredentialStore
}

// The demo's store, still listed after the real one was added.
struct DemoAccountsModule: AlulaModule {
    let credentialStore: any CredentialStore
}

// A module whose initializer takes the store, rather than an @Inject.
struct PasswordSignInModule: AlulaModule {
    init(credentialStore: any CredentialStore) {}
}

@main struct Main {
    static func main() async {
        await Alula.run(
            configuration: .load(),
            modules: [AccountsModule.self, DemoAccountsModule.self, PasswordSignInModule.self])
    }
}
