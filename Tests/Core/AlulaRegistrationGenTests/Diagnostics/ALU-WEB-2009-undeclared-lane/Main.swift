import AlulaWeb

@Controller("/admin", pipelines: ["audit"])
struct AdminController {
    @GetRoute("/stats")
    func stats(_ context: RequestContext) async throws -> String { "ok" }
}
