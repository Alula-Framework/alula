# Alula diagnostic codes

<!-- Generated from the pages in this directory — do not edit. Regenerate with:
     ALULA_REGENERATE_DIAGNOSTICS=1 swift test --filter DiagnosticCatalogTests -->

Every error and warning Alula reports carries one of these codes. Each page
says what the code means, why Alula rejects it, and how to fix it;
`alula explain <code>` prints the same page offline. Hangar's query codes,
`HGR-QUERY-4xxx`, are documented in
[Hangar's repository](https://github.com/Alula-Framework/hangar/tree/main/Diagnostics).

## Dependency injection and graph construction

| Code | Severity | |
|---|---|---|
| [ALU-DI-1001](ALU-DI-1001.md) | error | No module provides a required type |
| [ALU-DI-1002](ALU-DI-1002.md) | error | Several modules provide the same type |
| [ALU-DI-1003](ALU-DI-1003.md) | error | Components depend on each other in a cycle |
| [ALU-DI-1005](ALU-DI-1005.md) | error | @Inject(from:) names a module that does not provide the type |
| [ALU-DI-1006](ALU-DI-1006.md) | error | @Inject(from:) names a module the application does not include |
| [ALU-DI-1007](ALU-DI-1007.md) | error | @Inject(from:) names a module that provides the type more than once |
| [ALU-DI-1008](ALU-DI-1008.md) | error | @Inject of an optional type |
| [ALU-DI-1009](ALU-DI-1009.md) | warning | @Inject of a type nothing in the scan provides |
| [ALU-DI-1010](ALU-DI-1010.md) | warning | @Inject of a protocol several components conform to |
| [ALU-DI-1011](ALU-DI-1011.md) | warning | A module property has no written type |
| [ALU-DI-1012](ALU-DI-1012.md) | error | A component used from another module is not public |
| [ALU-DI-1013](ALU-DI-1013.md) | error | The removed `scope:` argument |
| [ALU-DI-1014](ALU-DI-1014.md) | error | The removed type-level `qualifier:` argument |
| [ALU-DI-1015](ALU-DI-1015.md) | error | Two @Inject properties of one type |
| [ALU-DI-1016](ALU-DI-1016.md) | error | An @Inject or @ConfigValue property has no written type |
| [ALU-DI-1017](ALU-DI-1017.md) | error | A stored property the generated initializer does not assign |
| [ALU-DI-1018](ALU-DI-1018.md) | error | @Component on something other than a struct or final class |
| [ALU-DI-1019](ALU-DI-1019.md) | error | @Inject or @ConfigValue on something other than a stored instance property |

## Controllers, routes, middleware, request binding

| Code | Severity | |
|---|---|---|
| [ALU-WEB-2001](ALU-WEB-2001.md) | error | Two handlers for one method and path |
| [ALU-WEB-2002](ALU-WEB-2002.md) | error | A route handler parameter Alula cannot bind |
| [ALU-WEB-2003](ALU-WEB-2003.md) | error | @Controller or @Middleware on something other than a struct or final class |
| [ALU-WEB-2004](ALU-WEB-2004.md) | error | A malformed route path |
| [ALU-WEB-2005](ALU-WEB-2005.md) | error | A route path that is not a string literal |
| [ALU-WEB-2006](ALU-WEB-2006.md) | error | A route handler declared in a way Alula cannot call |
| [ALU-WEB-2007](ALU-WEB-2007.md) | error | A route attribute outside a @Controller |
| [ALU-WEB-2008](ALU-WEB-2008.md) | warning | A route's pipelines drop its controller's authentication |
| [ALU-WEB-2009](ALU-WEB-2009.md) | warning | A route runs through a lane nothing declares |

## OpenAPI generation

| Code | Severity | |
|---|---|---|
| [ALU-OAPI-3001](ALU-OAPI-3001.md) | warning | A type the API uses has no schema |
| [ALU-OAPI-3002](ALU-OAPI-3002.md) | warning | A route's response cannot be described |

## Configuration

| Code | Severity | |
|---|---|---|
| [ALU-CONFIG-5001](ALU-CONFIG-5001.md) | error | @ConfigValue without a literal key |
| [ALU-CONFIG-5002](ALU-CONFIG-5002.md) | error | @Settings declared in a way Alula cannot bind |
| [ALU-CONFIG-5003](ALU-CONFIG-5003.md) | error | A @Settings property Alula cannot bind |
| [ALU-CONFIG-5004](ALU-CONFIG-5004.md) | error | A configuration key the base file does not define |
| [ALU-CONFIG-5005](ALU-CONFIG-5005.md) | error | A configuration prefix that cannot name environment variables |
| [ALU-CONFIG-5006](ALU-CONFIG-5006.md) | warning | The build could not check configuration keys |
| [ALU-CONFIG-5007](ALU-CONFIG-5007.md) | error | The base configuration file does not parse |
| [ALU-CONFIG-5008](ALU-CONFIG-5008.md) | error | A configuration value of the wrong type |
| [ALU-CONFIG-5009](ALU-CONFIG-5009.md) | error | A configuration source could not answer |
| [ALU-CONFIG-5010](ALU-CONFIG-5010.md) | error | No base configuration file at startup |
| [ALU-CONFIG-5011](ALU-CONFIG-5011.md) | error | Configuration refers to an unset environment variable |
| [ALU-CONFIG-5012](ALU-CONFIG-5012.md) | error | Configuration written for Flight, before the rename |
| [ALU-CONFIG-5013](ALU-CONFIG-5013.md) | error | A module's settings are invalid |

## Security and authentication composition

| Code | Severity | |
|---|---|---|
| [ALU-SEC-6001](ALU-SEC-6001.md) | error | A route requires roles but authenticates no one |
| [ALU-SEC-6002](ALU-SEC-6002.md) | error | Several modules provide the bearer-token validator |

## Commands

| Code | Severity | |
|---|---|---|
| [ALU-CMD-7001](ALU-CMD-7001.md) | error | Two modules declare one command name |
| [ALU-CMD-7002](ALU-CMD-7002.md) | error | No command by that name |

## Lifecycle and module composition

| Code | Severity | |
|---|---|---|
| [ALU-LIFE-8001](ALU-LIFE-8001.md) | error | Modules need each other in a cycle |
| [ALU-LIFE-8002](ALU-LIFE-8002.md) | error | No initializer of a module can be satisfied |
| [ALU-LIFE-8003](ALU-LIFE-8003.md) | error | A module contributes something nothing collects |

## Scheduled jobs

| Code | Severity | |
|---|---|---|
| [ALU-SCHED-9001](ALU-SCHED-9001.md) | error | A cron expression or time zone that does not parse |
| [ALU-SCHED-9002](ALU-SCHED-9002.md) | error | @Scheduled with no schedule, or with two |
| [ALU-SCHED-9003](ALU-SCHED-9003.md) | error | A @Scheduled argument that is not a literal |
| [ALU-SCHED-9004](ALU-SCHED-9004.md) | error | @Scheduled on a method Alula cannot run as a job |
| [ALU-SCHED-9005](ALU-SCHED-9005.md) | error | @Scheduler on something that schedules nothing |
