import AlulaCore

@Service
struct Clock {}

@Service
struct Greeter {
    @Inject var clock: Clock?
}
