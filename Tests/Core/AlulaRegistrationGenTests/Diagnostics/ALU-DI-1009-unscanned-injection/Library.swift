import AlulaCore

@Repository
struct UserRepository {
    @Inject var pool: DataSource
}
