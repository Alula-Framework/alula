import AlulaCore

@Service
struct Greeter {}

@Service
final class Welcomer {
    @Inject var greeter: Greeter
}

@Service
final class Farewell: Sendable {
    @Inject let greeter: Greeter
}

@MainActor
@Service
final class Screen {
    @Inject var greeter: Greeter
}
