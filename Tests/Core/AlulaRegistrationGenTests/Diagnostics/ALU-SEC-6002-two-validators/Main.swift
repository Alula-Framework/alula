import AlulaSecurity

struct CorporateSSOModule: AlulaModule {
    let validator: any TokenValidator
}

struct PartnerTokensModule: AlulaModule {
    let validator: any TokenValidator
}

@Service
struct Authenticator {
    @Inject var validator: any TokenValidator
}

@main struct Main {
    static func main() async {
        await Alula.run(
            configuration: .load(),
            modules: [CorporateSSOModule.self, PartnerTokensModule.self])
    }
}
