import AlulaWeb

struct AlulaOpenAPIModule: AlulaModule {
    init(configuration: Configuration, document: OpenAPIDocument) throws {}
}

@Controller("/reports")
struct ReportController {
    @GetRoute("/:id")
    func show(_ context: RequestContext, id: String) async throws -> Response { .noContent }

    // alula:undocumented-response — a download, deliberately untyped.
    @GetRoute("/:id/pdf")
    func pdf(_ context: RequestContext, id: String) async throws -> Response { .noContent }
}

@main struct Main {
    static func main() async {
        await Alula.run(configuration: .load(), modules: [AlulaOpenAPIModule.self])
    }
}
