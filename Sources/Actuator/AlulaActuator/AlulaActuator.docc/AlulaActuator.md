# ``AlulaActuator``

Health probes and a topology dashboard — with an exposure level that decides
what production is allowed to see.

## Overview

Registering the module adds at most five routes:

```
GET /actuator/health        every module running?
GET /actuator/health/live   is the process wedged — restart it?
GET /actuator/health/ready  can it serve traffic yet?
GET /actuator               the dashboard: modules and registered components
GET /actuator/info          which build is running (beside the dashboard)
```

That is the whole surface. There is no `/actuator/beans`, `/actuator/routes`
or `/actuator/config`. There are no metrics either,
by decision rather than omission: see `Docs/actuator.md` for why, and reach
for a metrics library when you want metrics.

What is served depends on ``ActuatorExposure``, and the default anywhere that
has not declared itself a development environment is
``ActuatorExposure/healthOnly`` — an orchestrator gets its probes and nothing
else leaks.

## Exposure is the safety property

- ``ActuatorExposure/disabled`` — nothing is registered at all.
- ``ActuatorExposure/healthOnly`` — the three health routes only. The
  default everywhere that has not said otherwise, *including a deployment
  that set nothing*: a default is not a declaration, and a production
  deployment that never set `ALULA_ENV` used to get the full dashboard.
- ``ActuatorExposure/full`` — the health routes plus the dashboard.

``ActuatorExposure/full`` is **open unless configured otherwise**. It
reports the module list and every registered component's fully-qualified type
name, plus each failed module's error text — a useful map of the application
to anyone who can reach it. Running it outside development means putting
authentication in front of it, and ``ActuatorDashboardAccess`` does that from
configuration: `actuator.dashboard-pipelines: authenticated` requires a
signed-in principal, and `actuator.dashboard-roles` requires a role. The
health routes are never gated.

## Constructing the module

The composition root calls
``ActuatorModule/init(configuration:components:health:healthChecks:logger:)``,
which reads the stated environment and every `actuator.*` setting; outside a
composition, `try ActuatorModule(configuration: configuration)` is the whole
call. ``ActuatorModule/init(environment:exposure:components:health:healthChecks:format:dashboardAccess:logger:)``
takes the same decisions in code, for tests and embedders.

## Health is composed from modules

Each `AlulaModule` gets a ``AlulaCore/ModuleHealth`` recorded for it by
Core: `.running` once it configures, `.failed` if its lifecycle service's
`run()` throws (the module's `service`, not a `@Service` component).
The actuator aggregates those and nothing else, so out of the box health
answers "did a module's service die", not "can this module reach its
database". A module that wants to say more calls
`reportHealth(_:forModule:)` on the `ModuleHealthRegistry` it is handed, on whatever cadence suits
it — a background check, a connection-pool callback — and the probes pick it
up. Nothing here polls and no check runs on the request path, which is what
removes the whole hung-check-and-timeout class of bug.

The two probes differ in one thing, and it is the thing that matters
operationally: a module that has not started yet counts against readiness and
not against liveness, so a slow-starting pod is not restarted into the same
slow start forever.

## Topics

### Configuration

- ``ActuatorModule``
- ``ActuatorExposure``
- ``ActuatorFormat``
- ``ActuatorConfigurationError``

### Dashboard access

- ``ActuatorDashboardAccess``
- ``ActuatorConfigKey``
- ``ActuatorDashboardAccessError``

### Output

- ``ActuatorSnapshot``
- ``ActuatorBuildInfo``
