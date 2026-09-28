// Every shape Docs/queue.md claims, compiled.
//
// A doc example that does not compile costs a reader the time to find out.
// This builds as part of `swift build`, so a rename that invalidates the
// prose breaks the build.
//
// The Postgres store and the in-transaction enqueue belong to alula-data
// (`AlulaQueuePostgres`), and `Alula.run(composedBy:)` needs the generated
// `alulaComposeModules`, so neither is compiled here.

import AlulaCore
import AlulaQueue
import AlulaQueueTesting
import Foundation

// snippet.hide
struct User: Sendable { let id: UUID }
struct UserRepository: Sendable {
    func create(email: String) async throws -> User { User(id: UUID()) }
}
struct WelcomeMailer: Sendable {
    func sendWelcome(to userID: UUID) async throws {}
}
/// Stands in for the graph `alula` generates for an application.
struct AlulaGraph: Sendable { let mailer: WelcomeMailer }
// snippet.show

// MARK: Jobs, enqueueing and handlers

struct SendWelcomeEmail: QueuedJob {
    static let queue = "mail"  // default "default"
    static let retry = RetryPolicy(maxAttempts: 5)  // default 10
    let userID: UUID
}

@Service
struct UserService {
    @Inject var repository: UserRepository
    @Inject var jobs: JobQueue

    func signup(email: String) async throws -> User {
        let user = try await repository.create(email: email)
        try await jobs.enqueue(SendWelcomeEmail(userID: user.id))
        return user
    }
}

func enqueueOptions(jobs: JobQueue, roomID: Int) async throws {
    // A delay or a runAt, a priority (lower first), a unique key, another queue.
    try await jobs.enqueue(
        SendWelcomeEmail(userID: UUID()),
        options: EnqueueOptions(delay: .seconds(30), priority: -1))
    let result = try await jobs.enqueue(
        SendWelcomeEmail(userID: UUID()),
        options: EnqueueOptions(
            runAt: Date().addingTimeInterval(60), uniqueKey: "digest-\(roomID)", queue: "reports"))
    switch result {
    case .enqueued(let id), .duplicate(let id): _ = id
    }
}

struct AppModule: AlulaModule {
    let queueHandlers: [QueueHandler]

    init(graph: AlulaGraph) {
        queueHandlers = [
            .handle(SendWelcomeEmail.self) { job, context in
                try await graph.mailer.sendWelcome(to: job.userID)
            }
        ]
    }
}

// MARK: Failure

func failureShapes() {
    // A handler's own timeout (default 300 s), and the stop-retrying error.
    _ = QueueHandler.handle(SendWelcomeEmail.self, timeout: .seconds(30)) { job, context in
        if context.isFinalAttempt { context.logger.warning("last try for \(job.userID)") }
        throw DiscardJob("the account no longer exists")
    }
    _ = RetryPolicy(maxAttempts: 10, base: .seconds(15), cap: .seconds(3600), jitter: 0.1)
    _ = RetryPolicy.never
}

// MARK: Shutdown

func shutdownDeadline() {
    // What the worker reads to hand jobs back before the bound.
    _ = ShutdownDeadline.current?.deadline
}

// MARK: Testing

func testingShapes() async throws {
    let harness = QueueTestHarness(handlers: [.handle(SendWelcomeEmail.self) { job, _ in }])
    _ = try await UserService(repository: UserRepository(), jobs: harness.queue)
        .signup(email: "a@example.com")
    let outcomes = await harness.drain()
    precondition(outcomes == [.completed])

    // A failing job waits for its retry until the clock says so:
    harness.advance(by: .seconds(15))
    await harness.drain()
}
