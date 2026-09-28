# Where Subsystems Meet

Each guide in this directory describes one subsystem, and each subsystem is
correct on its own terms. The bugs this page is about come from putting two
of them together: a job enqueued beside a transaction, a CSRF check beside
an API key, a retry beside a deadline. None of them is a defect in either
piece, and none of them shows up in either piece's tests.

Each section states the rule, says why, and links to the guides that own the
detail. It does not repeat them.

## A transaction and the work it causes

**Write the job, or the message, in the same transaction as the change that
causes it. Then make its handler safe to run twice.**

`JobQueue.enqueue` writes through the store on its own, separately from any
transaction the caller has open. Called after the commit, a crash between
the two loses the job, and an unreachable store throws after the change is
already permanent. Called before the commit, the job can run for a change
that then rolls back, or run before the change is visible to it.

With alula-data's Postgres store, the job can be a row in your own
transaction:

```swift
try await repo.transaction { tx in
    let order = try await tx.insert(order)
    _ = try await queueStore.enqueue(jobs.prepare(ShipOrder(id: order.id)), in: tx)
}
```

`jobs.prepare` only encodes. `enqueue(_:in:)` runs its `INSERT` on the `Repo`
you pass, so the job commits and rolls back with the order. A `uniqueKey`
still deduplicates, and the check sees your transaction's own uncommitted
jobs. Once committed, the job is a row in `alula_jobs` that any replica's
worker can claim, after a crash or a restart too. A job written this way
does not wake the local worker, so it starts on the next poll
(`queue.poll-interval-ms`, one second by default).

The transaction makes the *enqueue* atomic with the change. It does not make
the *handler* run exactly once. Delivery is still at least once: a worker
that dies mid-job, or whose lease lapses, leaves the job for another worker
to run again. A handler that writes to the database should key its write so
that a second run is a no-op, or record its own completion in the same
transaction as its effect.

**Publishing a PubSub message inside a transaction does not wait for the
commit.** The Postgres adapter's `pg_notify` runs on its own pooled
connection, so the message goes out at once whether the transaction later
commits or rolls back. To publish only what commits, use alula-data's
`Outbox`. `outbox.publish(_:to:in: tx)` writes the message as a queue job in
your transaction, and a queue worker hands it to `PubSub.publish` after the
commit. Be exact about how far that reaches:

- **Committed means handed to the bus, at least once.** A rolled-back
  message is never published. A committed one is published by whichever
  replica claims it, even after a crash. A worker that dies after publishing
  but before recording it publishes the message again, so each message
  carries an `outbox-id` in its metadata for subscribers that must not act
  twice.
- **Delivery to subscribers is still at most once.** The bus delivers to
  whoever is subscribed at that moment. A node whose listener is
  reconnecting misses the message. A bus that fails to forward it, such as a
  Postgres payload over the size limit, logs the failure, and the outbox job
  completes anyway. Nothing retries it.
- **No order.** Workers run jobs concurrently, so two messages written in
  sequence can be published in either order.
- **Up to one poll interval late**, for the same reason as the job above.

A consumer that must see every event, such as billing or a feed to an
external system, should consume a queue job of its own and not subscribe to
the bus.

Detail: [queue.md, Durability](queue.md#durability) and
[Delivery](queue.md#delivery-at-least-once);
[pubsub-postgres.md, Publishing on commit](https://github.com/Alula-Framework/alula-data/blob/main/Docs/pubsub-postgres.md#publishing-on-commit);
[pubsub.md, Semantics](pubsub.md#semantics-the-contract);
[core.md, Transactions](core.md#transactions).

## Sessions, CSRF, and credentials that are not cookies

**A browser proves who it is with a cookie, and CSRF protection guards that
cookie. Automation proves who it is with a bearer token or an API key, which
CSRF protection lets through. Keep the two apart.**

`CSRFProtection` checks every request except GET, HEAD, OPTIONS and TRACE,
on every route whose lanes include `Sessions`. It checks requests that carry
no cookie too, because `Sessions` gives every request a session. The token
must arrive on the `X-CSRF-Token` header, and without it the request gets a
bare 403. It passes two kinds of request unchecked:

- **A route with no `Sessions` in its lanes.** Nothing ambient is there to
  forge.
- **A request carrying `Authorization: Bearer …`.** A page on another site
  cannot make a browser attach a header it chose. Only the scheme is
  examined, not the token. `Basic` gets no pass, because browsers replay
  cached Basic credentials on their own.

`Authentication` takes a bearer token when one is present and falls back to
the session's principal when not. API keys (`sk_<id>_<secret>`, from
`AlulaAPIKeyModule`) are bearer tokens to it. So a machine client calling
with an API key needs no session and no CSRF token, even on a route whose
lane runs `Sessions` and `CSRFProtection`. A browser calling the same route
needs both.

What that implies:

- **The bearer exemption follows the same parse as authentication.** A
  `Authorization: Bearer` value that authentication would ignore (empty, or
  containing whitespace) is not exempt, so a request that ends up
  authenticated by its session cookie is always CSRF-checked. The exemption
  is safe because browsers will not send an `Authorization` header
  cross-site unless the preflight allows it. A CORS policy that allows
  `Authorization` with credentials from an origin you do not control
  extends the exemption to that origin.
- **Don't give automation a session cookie.** A script replaying a browser
  cookie has to fetch and echo the CSRF token, and it stops working at
  `sessions.authenticated-lifetime`. An API key has neither problem, and it
  can be revoked on its own.
- **Signing in and out change state.** Put them on a lane with
  `CSRFProtection` too. Login CSRF is real, and neither `SameSite=Lax` nor a
  JSON body stops it.

**Ordering.** A route's middleware is the lanes it names, concatenated in
the order it names them. Each lane runs in declaration order, outermost
first. `AlulaSessionsModule` puts `Sessions` in the default lane.
`AlulaSecurityModule` puts `Sessions` (when it is given a `SessionRuntime`)
and `Authentication` in `.default` and `.authentication`, and adds
`RequireAuthentication` in `.authenticated`. Nothing installs
`CSRFProtection`: you list it, after `Sessions`. Composition refuses a chain
in which `CSRFProtection` or `Authentication` comes before `Sessions`. It does
not refuse a chain with no `Sessions` at all, and there `CSRFProtection`
quietly checks nothing. A lane named in `pipelines:` has to be declared by
some module, or startup fails with `UndeclaredLaneError`. Security headers
are not middleware and are applied after every lane.

Detail: [web.md, CSRF](web.md#csrf), [Middleware lanes](web.md#middleware-lanes),
[Lanes per route](web.md#lanes-per-route) and [CORS](web.md#cors);
[sessions.md](sessions.md#sessions-and-identity);
[security-core.md, API keys](security-core.md#api-keys-and-more-than-one-kind-of-token)
and [Enforcement](security-core.md#enforcement);
[sign-in.md, the routes](sign-in.md#the-routes-written-once).

## Request deadlines and outbound retries

**Inside a request with a timeout, an outbound call spends the request's
time, not its own. Outside one, nothing bounds the total but the
attempts.**

`web.request-timeout-seconds`, or a route's own `timeout:`, sets a
deadline. When it passes, the client gets a 503 and the handler's task is
cancelled. The 503 does not wait for the handler to notice. Inside the
handler's task, `Deadline.current` is that instant. WebSocket upgrades never
have a deadline, and a route that streams its request body has one only
when it names one.

`OutboundHTTPClient` reads the deadline:

- Each attempt's timeout is the smaller of the configured one
  (`http-client.timeout-seconds`, 30 s) and the time left. An attempt with
  no time left is not sent at all. It throws `timedOut`.
- A retry happens only when its wait would end before the deadline.
  Otherwise the call ends there: a retryable status returns the last
  response, and a timeout or a broken connection throws.
- When the handler is cancelled, a backoff wait throws
  `CancellationError`, so the call stops there and makes no further
  attempts.

Only idempotent requests are retried: GET, HEAD, OPTIONS, PUT and DELETE,
any request carrying an `Idempotency-Key` header, and any request marked
`idempotent: true`. The retried failures are a timeout, a failure to
connect or a broken connection, and the statuses 429, 502, 503 and 504.
`Retry-After` is honoured up to 10 seconds. The backoff starts at 200 ms,
doubles up to 5 s, and is jittered down to between half and all of that.
`http-client.max-attempts` is 3 by default, the first included.

Where this bites:

- **A 503 from the deadline does not undo anything.** The handler ran until
  it was cancelled, and whatever it wrote stays written. An outbound POST
  that the other service had already read may have taken effect there.
  That is why a POST is retried only when it carries an `Idempotency-Key`
  that the other service honours.
- **The deadline does not travel.** Nothing sends it to the service being
  called. That service keeps working on a request its caller has already
  given up on.
- **The timeout covers the response head, not the body.** The body is read
  up to `http-client.max-response-bytes`, under AsyncHTTPClient's own idle
  read timeout.
- **Only a request has a deadline.** `Deadline.current` is a task-local, set
  for the handler's task and what it calls. A queue job, a scheduled job and
  a `Task.detached` get none, and there a call can take `max-attempts`
  timeouts plus the waits between them. A job enqueued from a request does
  not inherit the request's deadline either.

Detail: [web.md, Request timeouts](web.md#request-timeouts);
[http-client.md, When it retries](http-client.md#when-it-retries).

## Authentication and long-lived sockets

**A WebSocket is authenticated once, at the upgrade. Anything that later
changes who the user is — signing out everywhere, the authenticated lifetime
running out, a token expiring — does not reach a socket that is already
open.**

The upgrade is an ordinary GET through the route's lanes, so `Sessions` and
`Authentication` run on it like any other request. WebSocket origin
checking runs before either. The handler receives the `RequestContext` as it
stood after that middleware, and from then on no middleware runs.
For Channels, the principal comes from the `@WebSocketRoute` handler or the
`authenticate` closure of `socketRoute`, and it is a `let` on `Socket` for the
socket's whole life. The join gates, the pattern's `roles:` and then
`Channel.join`, run on each join against that principal.

`revokeSessions(ownedBy:)` deletes session records from the store and does
nothing else. The authenticated lifetime is checked by `Authentication`, and
`Authentication` runs on HTTP requests. Nothing keeps a registry of sockets by
user or session, and Channels has no server-side call to close one. A user
who is signed out keeps every socket, and every topic joined on it, until
the connection drops. Where that matters, check in the channel's own
handlers whatever must not outlive a sign-out. A plain WebSocket handler can
close its own connection.

**Reconnection re-authenticates.** `ChannelClient` re-dials with
`ReconnectPolicy` backoff and rejoins every topic it wanted. Every re-dial
is a new upgrade, so authentication runs again, and every rejoin runs the
join gates again. A rejoin that is refused comes back as `alula:error`, and
the topic is dropped. Two consequences for a Swift client:

- `WebSocketChannelTransport`'s headers are fixed when it is built. A
  cookie or token that has since been replaced is re-sent as it was. To
  send fresh credentials, implement `ChannelClientTransport` and read them
  in `connect(to:)`.
- The default policy (100 ms doubling to 10 s, no attempt limit) does not
  tell a refused handshake from a network failure, so a client whose
  credential was revoked keeps re-dialling. Pass `maxAttempts` where that
  matters.

Detail: [channels.md, Who may join what](channels.md#who-may-join-what),
[Swift client usage](channels.md#swift-client-usage) and
[Reconnection](channels.md#reconnection-resynchronises-it-does-not-replay);
[sessions.md, WebSocket routes](sessions.md#websocket-routes) and
[Signing out everywhere](sessions.md#signing-out-everywhere);
[web.md, WebSocket origins](web.md#websocket-origins).

## Shutdown order, the queue and the pools

**Shutdown runs by phase: inbound first, infrastructure last. Set
`lifecycle.shutdown-timeout-seconds` below your orchestrator's grace period,
and above your longest request or job.**

Each module's service has a `serviceShutdownPhase`. `.inbound` is the HTTP
server. `.standard` is the default, and it covers the queue worker, the
scheduler, PubSub, Presence and your own services. `.infrastructure` covers
the Postgres pool, the Postgres PubSub listener, the Valkey session and
rate-limit stores, and the SMTP transport. Services start in phase order and
stop in reverse, one at a time, each waited for, and in reverse dependency
order within a phase. Shutdown hooks run after their module's service
stops, in the same order, so a hook can still use the database.

On `SIGTERM`:

1. Readiness flips to "no", and the process keeps serving for
   `lifecycle.drain-seconds` (0 by default). The shutdown clock starts here.
2. The HTTP server stops, and its `run()` returns before anything behind
   it is told to stop.
3. The queue worker stops claiming and waits for its running jobs. Shortly
   before the deadline — two seconds, or a fifth of the timeout if that is
   less — it hands back the jobs still running. Their handlers are
   cancelled, and each job returns to `available`, due at once, while the
   pool is still open. The attempt is given back, so a job handed back on
   its final attempt still runs again. With no
   timeout configured, nothing is handed back, and the worker waits as long
   as its jobs take.
4. The pools close last. The Postgres pool waits up to 10 seconds for
   connections still checked out.

Past the timeout, everything still running is cancelled at once, the pools
included, so the order above no longer holds. The process prints
`alula: shutdown timed out.` with ALU-LIFE-8004, names the modules it cut
off, and exits 1. A job cut off then may be unable to record its result
with its pool already cancelled. If so, it stays `running` until its lease
(`queue.lease-seconds`) lapses, and then runs again.

alula-data's `ValkeyDataModule`, the Valkey cache and Valkey PubSub declare
no phase, so they stop in `.standard` beside the worker. Their order relative
to your own standard services is dependency order, not "last".

Detail: [core.md, Startup and shutdown hooks](core.md#startup-and-shutdown-hooks);
[queue.md, Shutdown](queue.md#shutdown);
[Diagnostics/ALU-LIFE-8004.md](../Diagnostics/ALU-LIFE-8004.md).

## What the OpenAPI document cannot promise

The document is generated from the route scan at build time, so it describes
what the declarations say and nothing the code decides at run time. A
handler that returns `Response` builds its body at run time, so the build
cannot see it. Types from packages the build does not scan are named but not
described. A hand-written `encode(to:)` is not followed. Framework routes
(Actuator, uploads, the document itself) are not `@Controller`s and are left
out. Middleware is invisible to the document, too: a 401 from
`RequireAuthentication`, a 403 from `CSRFProtection`, a 429 from rate
limiting and a 503 from a request timeout are real responses that no
handler signature declares. ALU-OAPI-3001 and the opt-in ALU-OAPI-3002 mark
the gaps at the route that causes them. Treat the document as the contract
of your handlers, and not of everything the process can answer. See
[openapi.md, Where it cannot see](openapi.md#where-it-cannot-see).
