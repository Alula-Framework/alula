import AlulaDiagnostics
import AlulaMacroSupport
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Scheduler` — the type-level half, mirroring `@Controller`.
///
/// A `@Scheduler` type is an ordinary singleton component: it may inject
/// dependencies with `@Inject` exactly as any other component does. What
/// this macro adds is one `ScheduledJobRegistration` per `@Scheduled` method,
/// wired the same way as everything else. Scheduling is not a separate system
/// from the rest of the component graph.
///
/// A separate attribute rather than teaching `@Service` about `@Scheduled`,
/// because that would make AlulaCore's macros depend on the scheduler's
/// vocabulary — the same reason `@Controller` exists rather than `@Service`
/// growing route awareness.
public struct SchedulerMacro: MemberMacro, ExtensionMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(ClassDeclSyntax.self) || declaration.is(StructDeclSyntax.self) else {
            context.diagnose(
                .invalidScheduler,
                "@Scheduler can only be attached to a class or struct.",
                at: node)
            return []
        }

        let jobs = JobScanning.scanJobs(of: declaration.memberBlock.members, in: context)
        guard !jobs.isEmpty else {
            context.diagnose(
                .invalidScheduler,
                """
                @Scheduler type has no @Scheduled methods, so it schedules nothing. Add \
                one, or drop @Scheduler and use @Service if this is an ordinary \
                component.
                """,
                at: node)
            return []
        }

        // Duplicate method names cannot happen, but duplicate *job* names can
        // if someone hand-writes the same qualifier. The qualifier embeds
        // the fully-qualified type so two schedulers may share a method name.
        var jobValueLines: [String] = []
        for job in jobs {
            jobValueLines.append(contentsOf: valueLines(for: job))
        }

        // Mirrors the type's access, as every registration macro does: a
        // `package` scheduler gets `package` members. This once mapped only
        // `public`/`open`, so a `package` scheduler's members were internal
        // and unreachable from another module of its own package.
        let access = registrationAccess(for: declaration)

        // A @Scheduler type is an ordinary component: it injects what its
        // jobs need, exactly as @Controller and @Service do. Without the
        // generated initializer, @Inject in a scheduler would not compile
        // — which the compiled doc snippet caught.
        let properties = collectInjectedProperties(from: declaration, in: context)

        // The jobs as values, built from a component the caller supplies —
        // the composition root fills `make` with the component the graph
        // built. This is the whole of what @Scheduler emits for wiring; the
        // container-era resolving init and registration thunk are gone.
        let jobValues: DeclSyntax = """
            \(raw: access)static func _alulaScheduledJobs(
                _ make: @escaping @Sendable () -> Self
            ) -> [AlulaScheduler.ScheduledJobRegistration] {
                [
            \(raw: jobValueLines.map { "        " + $0 }.joined(separator: "\n"))
                ]
            }
            """
        // Constructor injection, through the same generator @Service,
        // @Controller and @Middleware use.
        let parameterInit = parameterizedInitializer(
            properties: properties, access: access, declaration: declaration)
        return [parameterInit, jobValues].compactMap { $0 }
    }

    /// One `ScheduledJobRegistration` literal, closing over `make()`.
    private static func valueLines(for job: ScannedJob) -> [String] {
        var call = "component.\(job.methodName)()"
        if job.isAsync { call = "await \(call)" }
        if job.isThrows { call = "try \(call)" }

        var lines: [String] = []
        lines.append("AlulaScheduler.ScheduledJobRegistration(")
        lines.append("    name: String(reflecting: Self.self) + \".\(job.methodName)\",")
        lines.append("    trigger: \(trigger(for: job)),")
        lines.append("    scope: \(job.scopeText),")
        lines.append("    overlap: \(job.overlapText)")
        lines.append(") {")
        lines.append("    let component = make()")
        lines.append("    \(call)")
        lines.append("},")
        return lines
    }

    /// Shared by both forms, so the schedule cannot drift between them.
    private static func trigger(for job: ScannedJob) -> String {
        switch job.schedule {
        case .cron(let text, let timeZone):
            // Force-try is safe here and nowhere else: the expression was
            // parsed by this same parser at compile time, so a throw is
            // impossible unless the macro and the runtime disagree — which
            // sharing one parser rules out.
            return
                "AlulaScheduler.JobTrigger.cron("
                + "try! AlulaScheduler.CronExpression(\"\(text)\"), "
                + "timeZone: try! AlulaScheduler._alulaTimeZone("
                + "\(timeZone), job: String(reflecting: Self.self) + \".\(job.methodName)\"))"
        case .interval(let every, let initialDelay):
            let delay = initialDelay ?? ".seconds(0)"
            return "AlulaScheduler.JobTrigger.interval(\(every), initialDelay: \(delay))"
        }
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // No conformance to emit: the container marker protocol is gone.
        []
    }
}
