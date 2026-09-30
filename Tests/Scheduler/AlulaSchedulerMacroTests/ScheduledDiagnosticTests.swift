// The compile-time half of the scheduler's pitch: a bad schedule is a build
// error naming the problem, not a job that silently never fires.
//
// These pin the *diagnostics* rather than the expansion. A diagnostic that
// gets reworded or silently vanishes is exactly the kind of regression that
// nothing else catches — the code still compiles, it just stops helping.

import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import AlulaDiagnostics
import Testing

@testable import AlulaSchedulerMacrosImpl

private let testMacros: [String: MacroSpec] = [
    "Scheduler": MacroSpec(type: SchedulerMacro.self, conformances: ["AlulaCore._AlulaRegistrable"]),
    "Scheduled": MacroSpec(type: ScheduledMacro.self),
]

@Suite("scheduler macro diagnostics")
struct ScheduledDiagnosticTests {

    private func expectDiagnostic(
        _ source: String,
        _ code: DiagnosticCode,
        _ expectedMessageFragment: String,
        sourceLocation: Testing.SourceLocation = #_sourceLocation
    ) {
        var messages: [String] = []
        assertMacroExpansion(
            source, expandedSource: "", macroSpecs: testMacros,
            failureHandler: { failure in messages.append(failure.message) },
            fileID: #fileID, filePath: #filePath, line: UInt(sourceLocation.line), column: 1)
        #expect(
            messages.contains { $0.contains("[\(code.id)]") && $0.contains(expectedMessageFragment) },
            "no \(code.id) diagnostic mentioning \"\(expectedMessageFragment)\"; got: \(messages)",
            sourceLocation: sourceLocation)
    }

    @Test("a malformed cron expression fails the build, naming the field")
    func malformedCron() {
        // The whole reason the expression must be a literal.
        expectDiagnostic(
            """
            @Scheduler
            struct Jobs {
                @Scheduled("0 0 25 * * *")
                func run() {}
            }
            """,
            .invalidSchedule, "hour")
    }

    @Test("the wrong number of fields says how many it found")
    func wrongFieldCount() {
        expectDiagnostic(
            """
            @Scheduler
            struct Jobs {
                @Scheduled("0 0")
                func run() {}
            }
            """,
            .invalidSchedule, "found 2")
    }

    @Test("a non-literal expression explains the runtime alternative")
    func nonLiteral() {
        expectDiagnostic(
            """
            @Scheduler
            struct Jobs {
                @Scheduled(schedule)
                func run() {}
            }
            """,
            .nonLiteralScheduleArgument, "ScheduledJobRegistration")
    }

    @Test("a job taking parameters is refused, naming the alternative")
    func parametersRefused() {
        expectDiagnostic(
            """
            @Scheduler
            struct Jobs {
                @Scheduled("0 0 3 * * *")
                func run(now: Date) {}
            }
            """,
            .invalidScheduledMethod, "@Inject")
    }

    @Test("a job returning a value is refused, because nothing reads it")
    func returnValueRefused() {
        expectDiagnostic(
            """
            @Scheduler
            struct Jobs {
                @Scheduled("0 0 3 * * *")
                func run() -> Int { 0 }
            }
            """,
            .invalidScheduledMethod, "nothing reads")
    }

    @Test("both a cron expression and an interval is refused")
    func twoSchedules() {
        expectDiagnostic(
            """
            @Scheduler
            struct Jobs {
                @Scheduled("0 0 3 * * *", every: .minutes(5))
                func run() {}
            }
            """,
            .missingOrConflictingSchedule, "Pick one")
    }

    @Test("@Scheduler with no jobs says so rather than silently doing nothing")
    func noJobs() {
        expectDiagnostic(
            """
            @Scheduler
            struct Jobs {
                func run() {}
            }
            """,
            .invalidScheduler, "schedules nothing")
    }

    @Test("@Scheduled on something that is not a method is refused")
    func notAMethod() {
        expectDiagnostic(
            """
            @Scheduler
            struct Jobs {
                @Scheduled("0 0 3 * * *")
                var value: Int = 0
            }
            """,
            .invalidScheduledMethod, "can only be attached to a method")
    }

    // @Scheduler had its own copy of the @Inject scan, which skipped a static
    // property silently. It shares @Service's now, diagnostic included.
    @Test("a static @Inject is ALU-DI-1019, as on @Service")
    func staticInject() {
        expectDiagnostic(
            """
            @Scheduler
            struct Jobs {
                @Inject static var clock: Clock
                @Scheduled("0 0 3 * * *")
                func run() {}
            }
            """,
            .invalidInjectionTarget, "a static property has no instance to belong to")
    }

    // A `package` scheduler's generated members used to be internal: its
    // access rule mapped only `public`/`open`, where every other registration
    // macro mirrors `package` too. Internal members cannot be reached from
    // another module of the same package, which is where the composition
    // root may live. This pins the corrected expansion.
    @Test("a package @Scheduler gets package members")
    func packageAccess() {
        assertMacroExpansion(
            """
            @Scheduler
            package struct Jobs {
                @Inject var clock: Clock
                @Scheduled(every: .minutes(5))
                func run() {}
            }
            """,
            expandedSource: """
                package struct Jobs {
                    @Inject var clock: Clock
                    func run() {}

                    package init(clock: Clock) {
                        self.clock = clock
                    }

                    package static func _alulaScheduledJobs(
                        _ make: @escaping @Sendable () -> Self
                    ) throws -> [AlulaScheduler.ScheduledJobRegistration] {
                        [
                            AlulaScheduler.ScheduledJobRegistration(
                                name: String(reflecting: Self.self) + ".run",
                                trigger: AlulaScheduler.JobTrigger.interval(.minutes(5), initialDelay: .seconds(0)),
                                scope: .once,
                                overlap: .skip
                            ) {
                                let component = make()
                                component.run()
                            },
                        ]
                    }
                }
                """,
            macroSpecs: testMacros)
    }

    // The time zone was checked against the build machine's database; the
    // deployment's may lack it. The expansion used `try!`, so that crashed
    // at composition with a backtrace. It is `try` now, in a throwing
    // factory, and `Alula.run` reports ALU-SCHED-9001.
    @Test("a cron job's time zone is resolved with try, never try!")
    func cronTimeZoneThrows() {
        assertMacroExpansion(
            """
            @Scheduler
            struct Jobs {
                @Scheduled("0 0 3 * * *", timeZone: "America/New_York")
                func nightly() {}
            }
            """,
            expandedSource: """
                struct Jobs {
                    func nightly() {}

                    init() {
                    }

                    static func _alulaScheduledJobs(
                        _ make: @escaping @Sendable () -> Self
                    ) throws -> [AlulaScheduler.ScheduledJobRegistration] {
                        [
                            AlulaScheduler.ScheduledJobRegistration(
                                name: String(reflecting: Self.self) + ".nightly",
                                trigger: AlulaScheduler.JobTrigger.cron(try AlulaScheduler.CronExpression("0 0 3 * * *"), timeZone: try AlulaScheduler._alulaTimeZone("America/New_York", job: String(reflecting: Self.self) + ".nightly")),
                                scope: .once,
                                overlap: .skip
                            ) {
                                let component = make()
                                component.nightly()
                            },
                        ]
                    }
                }
                """,
            macroSpecs: testMacros)
    }
}
