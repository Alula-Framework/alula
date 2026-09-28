import AlulaWeb

struct AlulaOpenAPIModule: AlulaModule {
    init(configuration: Configuration, document: OpenAPIDocument) throws {}
}

@Controller("/reports")
struct ReportController {
    @GetRoute("/:id")
    func show(_ context: RequestContext, id: String) async throws -> Response { .noContent }

    @GetRoute("/:id/summary")
    func summary(_ context: RequestContext, id: String) async throws -> Report { Report() }
}

struct Report: Codable {
    var title = ""
}

@main struct Main {
    static func main() async {
        await Alula.run(configuration: .load(), modules: [AlulaOpenAPIModule.self])
    }
}
