import AlulaWeb

@Controller("/users")
struct UsersController {
    @GetRoute("/:id")
    func show(_ context: RequestContext, id: String) async throws -> String { id }
}

@Controller("/users")
struct AdminUsersController {
    @GetRoute("/:userID")
    func detail(_ context: RequestContext, userID: String) async throws -> String { userID }
}
