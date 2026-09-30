# Alula Documentation

Organised by what you are trying to do, not by which package or target
ships it. A link into a section (`#…`) means the concept lives inside a
larger guide. Links to `alula-data` and `hangar` go to those repositories.

## Start here

- [README, Getting started](../README.md#getting-started): the package line, a first application, `ALULA_ENV=dev`, and the traits that turn products on.
- [Fledge](https://github.com/Alula-Framework/fledge): the tutorial, from an empty directory to a clustered app, plus its guides. It runs locally; it is not hosted.
- [API reference](https://alula-framework.github.io/fledge/): the DocC reference for alula, alula-data, Hangar and swift-changeset, rebuilt weekly from `main`.
- [Where subsystems meet](interactions.md): read before combining transactions with jobs, cookies with API keys, or deadlines with retries.

## Core concepts

- [Modules and composition](core.md#modules): how an application is assembled, and why wiring is checked at build time ([compile-time wiring](core.md#compile-time-wiring)).
- [Two providers of one type](core.md#two-providers-of-one-type): when the build refuses an ambiguous graph.
- [Lifetimes](core.md#lifetimes): singleton is the only one, and where per-request state goes instead.
- [Components should be `Sendable`](core.md#components-should-be-sendable): the concurrency rule the graph assumes.
- [Configuration](config.md): layering, environments, the YAML subset, [secrets](config.md#substitution-and-secrets), [environment variables](config.md#environment-variables).
- [Configuration as a typed value](core.md#configuration-as-a-typed-value): reading config into a struct a module owns.
- [Startup and shutdown hooks](core.md#startup-and-shutdown-hooks): one-shot work at either end, and the shutdown timeout.
- [Shutdown order](interactions.md#shutdown-order-the-queue-and-the-pools): phases, draining, and what happens at the timeout.
- [What it prints on exit](core.md#what-it-prints-on-exit): the exit report and codes.
- [Commands](core.md#commands): one-off tasks (a data fix, an import) run with the application's graph.
- [Logging](core.md#logging): where logs go and what they carry.

## HTTP

- [Routes and controllers](web.md#using-it): the first stop for anything served over HTTP.
- [Path](web.md#path-parameters-arrive-typed) and [query parameters](web.md#query-parameters-decode-into-a-type): typed, with a 400 that names the bad one.
- [Validation](web.md#validation) and [what a thrown error becomes](web.md#what-a-thrown-error-becomes): request bodies and error responses.
- [Middleware lanes](web.md#middleware-lanes) and [lanes per route](web.md#lanes-per-route): ordering, and a different stack per route.
- [Request timeouts](web.md#request-timeouts): deadlines per route, and `Deadline.current`.
- [Bodies](web.md#bodies), [files, assets and uploads](web.md#files-assets-and-uploads), [compression](web.md#compression): large and binary payloads.
- [Refusing lost updates](web.md#refusing-lost-updates): ETags and write preconditions.
- [Cookies](web.md#cookies), [redirects](web.md#redirects), [wire format](web.md#wire-format): response details.
- [CORS](web.md#cors): browsers calling from another origin.
- [HTTPS](web.md#https): TLS in the process itself, when nothing in front terminates it.
- [Connection timeouts](web.md#connection-timeouts): idle and stalled connections, as opposed to slow requests.
- [Client address](client-address.md): the real caller behind a proxy, and why nothing is trusted by default.
- [Rate limiting](rate-limiting.md): per-key limits on requests or anything else; [Valkey store](https://github.com/Alula-Framework/alula-data/blob/main/Docs/rate-limit-valkey.md) for more than one process.
- [OpenAPI](openapi.md): a document generated at build time, and [where it cannot see](openapi.md#where-it-cannot-see).

## Persistence

- [Hangar](https://github.com/Alula-Framework/hangar/blob/main/README.md): queries, schemas and the repo; start here for SQL.
- [Hangar, what it does](https://github.com/Alula-Framework/hangar/blob/main/README.md#what-it-does): preloading, transactions with savepoints, changesets.
- [Hangar, queries Postgres would reject do not compile](https://github.com/Alula-Framework/hangar/blob/main/README.md#queries-postgres-would-reject-do-not-compile): the build-time checks.
- [Hangar, binding a repo to a connection you own](https://github.com/Alula-Framework/hangar/blob/main/README.md#binding-a-repo-to-a-connection-you-own): using Hangar inside someone else's connection.
- [Hangar, starting from a database you already have](https://github.com/Alula-Framework/hangar/blob/main/README.md#starting-from-a-database-you-already-have): generating schemas from a live database.
- [Transactions](core.md#transactions): why a closure and not an annotation; [on Postgres](https://github.com/Alula-Framework/alula-data/blob/main/Docs/data-postgres.md#transactions).
- [Data core](https://github.com/Alula-Framework/alula-data/blob/main/Docs/data-core.md): data sources and pools, and [what a pool size means](https://github.com/Alula-Framework/alula-data/blob/main/Docs/data-core.md#what-a-pool-size-actually-means).
- [Postgres](https://github.com/Alula-Framework/alula-data/blob/main/Docs/data-postgres.md): the driver, [database failures as a client sees them](https://github.com/Alula-Framework/alula-data/blob/main/Docs/data-postgres.md#what-a-client-sees-when-the-database-fails), [read replicas](https://github.com/Alula-Framework/alula-data/blob/main/Docs/data-postgres.md#read-replicas), [streaming](https://github.com/Alula-Framework/alula-data/blob/main/Docs/data-postgres.md#streaming-holds-a-connection-for-as-long-as-the-client-reads).
- [Migrations](https://github.com/Alula-Framework/alula-data/blob/main/Docs/migrate.md): writing and running them, and [the guarantees, precisely](https://github.com/Alula-Framework/alula-data/blob/main/Docs/migrate.md#the-guarantees-precisely).
- [Valkey](https://github.com/Alula-Framework/alula-data/blob/main/Docs/data-valkey.md): the client, and [what happens when the server goes away](https://github.com/Alula-Framework/alula-data/blob/main/Docs/data-valkey.md#what-happens-when-the-server-goes-away).
- [Caching](https://github.com/Alula-Framework/alula-data/blob/main/Docs/cache.md): cached methods, and [on Valkey](https://github.com/Alula-Framework/alula-data/blob/main/Docs/cache-valkey.md).

## Security

- [Authentication and roles](security-core.md#quick-start): validating tokens your identity provider issued, and [roles on routes](security-core.md#roles-are-declared-on-the-route).
- [Choosing how tokens are validated](security-core.md#choosing-how-tokens-are-validated) and [what the validator enforces](security-core.md#what-the-validator-enforces).
- [API keys](security-core.md#api-keys-and-more-than-one-kind-of-token): credentials for machines, beside user tokens.
- [Webhook signatures](security-core.md#webhook-signatures): verifying calls from another service.
- [Signing in](sign-in.md): passwords or OpenID Connect behind one seam, and [signing out everywhere](sign-in.md#signing-out-everywhere).
- [Hashing a password](security-core.md#hashing-a-password): Argon2id, and why.
- [Sessions](sessions.md): server-side sessions, [the authenticated lifetime](sessions.md#the-authenticated-lifetime), [one-time links](sessions.md#one-time-links); [on Valkey](https://github.com/Alula-Framework/alula-data/blob/main/Docs/sessions-valkey.md).
- [CSRF](web.md#csrf): what is checked, what is exempt, and [how it meets API keys](interactions.md#sessions-csrf-and-credentials-that-are-not-cookies).
- [Security headers](web.md#security-headers): defaults, HSTS and CSP.
- [WebSocket origins](web.md#websocket-origins): which pages may open a socket.
- [Actuator access](actuator.md#access-gating): keeping the dashboard behind authentication.

## Background work

- [Queue](queue.md): jobs that must happen, at least once, with retries and dead letters.
- [Transactional enqueue](queue.md#durability): a job that commits with the change that caused it; [the rule in full](interactions.md#a-transaction-and-the-work-it-causes).
- [Scheduler](scheduler.md): cron and interval jobs, and [running once across many servers](scheduler.md#running-once-on-one-server-or-many).
- [Mail](mail.md): sending through the queue, and SMTP.

## Realtime

- [WebSockets and server-sent events](web.md#using-it): routes that upgrade or stream; [subprotocols and pings](web.md#websocket-subprotocols-and-pings).
- [PubSub](pubsub.md): topics within a node and [across a cluster](pubsub.md#multi-node); [on Postgres](https://github.com/Alula-Framework/alula-data/blob/main/Docs/pubsub-postgres.md).
- [Channels](channels.md): topics over a socket, [who may join what](channels.md#who-may-join-what), and [reconnection](channels.md#reconnection-resynchronises-it-does-not-replay).
- [Authentication on sockets](interactions.md#authentication-and-long-lived-sockets): what happens at upgrade, and what revocation cannot reach.
- [Presence](presence.md): who is here, across a cluster.

## External services

- [HTTP client](http-client.md): timeouts, [which requests are retried](http-client.md#when-it-retries), and [calling as a service account](http-client.md#calling-as-a-service-account).
- [Deadlines and retries together](interactions.md#request-deadlines-and-outbound-retries): what an outbound call spends inside a request.
- [APNs](apns.md): push notifications to Apple devices.

## Operations

- [Actuator](actuator.md): [health probes](actuator.md#the-health-probes), build info, and the topology dashboard.
- [Telemetry](telemetry.md): the metrics, traces and logs Alula emits, and [contributing your own](telemetry.md#contributing-metrics).
- [Queue telemetry](queue.md#telemetry): the depth and failure metrics worth alerting on.
- [Shutdown timeout](core.md#startup-and-shutdown-hooks): setting it against your orchestrator's grace period.

## Testing

- [Testing an application](testing.md): three sizes of test, and [routes under test](testing.md#routes-under-test--the-usual-choice), the usual choice.
- [Testing the layers](testing.md#testing-the-layers): HTTP, PubSub, Channels, data, sessions, cache and telemetry test support.
- [What still needs a real server](testing.md#what-still-needs-a-real-server).
- Per subsystem: [queue](queue.md#testing), [scheduler](scheduler.md#testing-without-sleeping), [rate limiting](rate-limiting.md#testing), [APNs](apns.md#testing), [HTTP client](http-client.md#testing), [migrations](https://github.com/Alula-Framework/alula-data/blob/main/Docs/migrate.md#testing-your-migrations).

## Reference

- [Diagnostic codes](../Diagnostics/README.md): every `ALU-…` code, what it means and how to fix it; `alula explain <code>` prints the same page.
- [Decisions](../DECISIONS.md): the judgement calls, with the alternatives they were chosen over.
- [Changelog](../CHANGELOG.md): what changed in each release.
- [Traits](../README.md#traits): which trait turns on which product.
