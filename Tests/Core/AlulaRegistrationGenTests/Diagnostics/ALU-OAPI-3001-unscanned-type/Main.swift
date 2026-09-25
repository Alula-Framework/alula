import AlulaWeb
import Currency

struct AlulaOpenAPIModule: AlulaModule {
    init(configuration: Configuration, document: OpenAPIDocument) throws {}
}

struct Order: Codable {
    let id: UUID
    let total: Money  // declared in a package this build does not scan
}

@Controller("/orders")
struct OrderController {
    @GetRoute("/:id")
    func show(_ context: RequestContext, id: UUID) async throws -> Order { fatalError() }

    @GetRoute("")
    func list(_ context: RequestContext) async throws -> [Order] { [] }
}

@main struct Main {
    static func main() async {
        await Alula.run(configuration: .load(), modules: [AlulaOpenAPIModule.self])
    }
}
