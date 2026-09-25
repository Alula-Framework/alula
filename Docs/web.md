# Alula Web

The HTTP request lifecycle layer of Alula — routing, middleware, request and
response representation, WebSocket and Server-Sent Events, and the
`ServerTransport` seam a concrete server plugs in underneath (the
Phoenix/Bandit relationship, not bring-your-own-framework). Implements the
alula-web design doc (as revised: §5.2 wraps a maintained low-level
transport instead of hand-rolling HTTP; §5.6 containment) on top of Alula
Core's `AlulaModule` composition — through exactly one channel,
`AlulaModule`, like every other Alula package.

## Adding this module

| | |
|---|---|
| **Trait** | `Web` |
| **Products** | `AlulaWeb`, `AlulaTransport` |
| **Module** | `AlulaWebModule<AlulaTransport>.self` |

```swift
// Package.swift
dependencies: [
    .package(
        url: "https://github.com/Alula-Framework/alula.git",
        from: "0.36.0", traits: ["Web"]),
],
targets: [
    .executableTarget(
        name: "App",
        dependencies: [
            .product(name: "AlulaCore", package: "alula"),
            .product(name: "AlulaWeb", package: "alula"),
            .product(name: "AlulaTransport", package: "alula"),
        ],
        // Required. It scans this target for the Alula macros and writes
        // `alulaComposeModules`; without it there is no composition root
        // to pass to `Alula.run`.
        plugins: [.plugin(name: "AlulaRegistrationPlugin", package: "alula")]
    )
]
```

```swift
// Sources/App/Main.swift — *not* `main.swift`, which is top-level code and
// cannot coexist with @main.
import AlulaCore
import AlulaTransport
import AlulaWeb

@main
struct Main {
    static func main() async {
        await Alula.run(
            configuration: try Configuration.load(),
            modules: [AlulaWebModule<AlulaTransport>.self, AppModule.self],
            composedBy: alulaComposeModules)
    }
}
```

Choosing a transport is choosing a module: `AlulaWebModule` is generic over
`ServerTransport`, and `AlulaTransport` is the HummingbirdCore-backed one
this package ships. Any conforming transport is a peer.

The `modules:` list names roots, not an order — the build resolves the
dependency DAG. A module you write can declare framework modules in its own
`dependencies`, in which case listing yours is enough.

## What's here

| Product | Contents |
|---|---|
| `AlulaWeb` | `RequestContext`, `Request`/`Response`, middleware lanes, `Router`, `@Controller`/`@GetRoute`/…/`@WebSocketRoute` macros, `ResponseEncodable`, cookies, SSE, streaming bodies, multipart, resumable uploads, static assets, `serveContent`'s conditional/range engine, `WebSocketUpgradeHandler`/`WebSocketConnection`, `ServerTransport` protocol, `AlulaWebModule`, `Sessions`/`AlulaSessionsModule` (see [sessions.md](sessions.md)), `RateLimiting` (see [rate-limiting.md](rate-limiting.md)), `TrustedProxies`/`clientAddress` (see [client-address.md](client-address.md)) |
| `AlulaTransport` | The default transport (§5.2): wraps **HummingbirdCore** — a mature, versioned low-level HTTP transport — for HTTP/1.1 (keep-alive, pipelining, 100-continue), streaming bodies, and WebSocket protocol handling. The only target in all of Alula that knows what it wraps (§5.6) |
| `AlulaWebTesting` | `RequestContext.mock`, `TestClient` (in-process dispatch + in-process WebSocket), `InMemoryTransport` (§5.4's socket-free transport) |

## Using it

```swift
import AlulaCore
import AlulaWeb
import AlulaTransport

@Controller
struct UserController {
    @Inject var userService: UserService          // Alula Core DI, unchanged

    @GetRoute("/users/:id")
    func getUser(_ context: RequestContext, id: UUID) async throws -> UserResponse {
        try await userService.find(id)               // UserResponse: Codable + ResponseEncodable
    }

### Path parameters arrive typed

A handler parameter named after a `:segment` receives it parsed:

```swift
@GetRoute("/orders/:orderID/lines/:line")
func line(_ context: RequestContext, orderID: UUID, line: Int) async throws -> Line
```

The label *is* the segment it binds to, so the two cannot drift apart — asking
for a segment the path does not declare is a build error naming the ones it
does:

```
error: Route handler 'user' takes 'slug:', but no path segment is named
':slug' — declared: :id. A path parameter's label is the segment it binds to,
so the two cannot drift apart.
```

A segment that will not parse never reaches the handler: it is a 400 naming
the parameter and the type it expected. `String`, the integer types, `Double`,
`Bool` and `UUID` are understood; conform `PathParameterConvertible` for
anything else, and the rule for what the segment may be lives at the edge
rather than in every handler that receives it:

```swift
struct Slug: PathParameterConvertible {
    let value: String
    init?(pathParameter text: String) {
        guard text.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" })
        else { return nil }
        self.value = text
    }
}
```

`context.pathParam("id")` still returns the raw `String`, and
`context.pathParam("id", as: UUID.self)` parses one where a handler signature
cannot reach — inside middleware, say.

### Query parameters decode into a type

A `query:` parameter is decoded from the query string the way `body:` is
decoded from the body:

```swift
struct ListFilters: Decodable {
    var search: String?
    var page: Int?
    var tags: [String]?
    var tenant: String        // required
}

@GetRoute("/posts")
func list(_ context: RequestContext, query: ListFilters) async throws -> [Post]
```

`?tenant=acme&page=3&tags=a&tags=b` arrives parsed: `page` is an `Int`, and a
repeated key collects into an array — the same rules as a form body, because
a query string is the same wire format.

**Optional means optional, and non-optional means required.** Swift's
synthesized `Decodable` does not fall back to a property's default value when
a key is absent; it throws. So `var page: Int?` is the right spelling for
"may be absent" — `page ?? 1` at the point of use — and `var tenant: String`
says the request must carry it, which is a 400 naming the parameter rather
than a silent default. A missing key, a value of the wrong type and a
malformed query each produce a 400 that names the parameter at fault.

`context.query(ListFilters.self)` does the same decoding where a handler
signature cannot reach, and `request.queryParam("page")` still returns the raw
`String?`.
```swift
    @PostRoute("/users")
    func createUser(_ context: RequestContext, body: CreateUserRequest) async throws -> UserResponse {
        try await userService.create(body)
    }

    @WebSocketRoute("/chat/:roomId")               // §6.1 — same route table
    func chat(_ context: RequestContext, roomId: String) throws -> any WebSocketUpgradeHandler {
        ChatRoomHandler(roomId: roomId)
    }

    @GetRoute("/events")                           // §6.2 — SSE is a response shape
    func events(_ context: RequestContext) -> Response {
        .serverSentEvents { events in
            // `send` suspends until the event has gone out, and answers
            // false once the client is gone — the producer is paced by the
            // reader rather than buffered ahead of it.
            await events.send(data: "hello", event: "greeting")
        }
    }


    @Middleware
    struct Authentication: Middleware {
        func handle(_ context: RequestContext, next: Next) async throws -> Response {
            guard context.request.headers[.authorization] != nil else {
                return .problem(status: .unauthorized, message: "Unauthorized")
            }
            return try await next(context)
        }
    }

    struct AppModule: AlulaModule {
        // The default lane, outermost first — provided as values the composition
        // root hands AlulaWebModule. The app's controllers and components are
        // scanned by the build plugin and wired by the composition root; nothing
        // is registered here.
        let middleware = MiddlewareRegistration.lane(.default, [RequestLogging(), Authentication()])
    }

    @main struct Main {
        static func main() async {
            await Alula.run(                             // prints why and exits 1 if it cannot start
                configuration: try Configuration.load(),
                modules: [AlulaWebModule<AlulaTransport>.self, AppModule.self],
                composedBy: alulaComposeModules          // generated by the build plugin
            )
        }
    }
```

Transport settings come from the same `alula.yaml` everything else uses:
`server.host` (127.0.0.1), `server.port` (8080), `server.backlog`,
`server.max-request-body-bytes`, `server.max-websocket-frame-bytes`,
`server.websocket-ping-seconds`.

### Request timeouts

A route can bound how long a request may take. Past the limit the client gets
`503`, and the handler's task is cancelled:

```swift
@GetRoute("/report", timeout: .seconds(120))   // slower than the default
@GetRoute("/poll", timeout: .none)             // long polling: no limit
```

```yaml
web:
  request-timeout-seconds: 30   # every route that does not name its own
```

Unset, there is no default limit, so an application upgrading sees no change
until it opts in. The limit covers the middleware and the handler until the
response is ready, not the time spent writing a streamed response. A
WebSocket upgrade never has one. A route streaming its request body has one
only when it names it, because an upload's length is the client's to decide.

The answer does not wait for the handler. A handler blocked in code that
ignores cancellation still lets the 503 go out on time, and cancellation
reaches the handler as soon as it next checks.

Inside the request, `Deadline.current` (AlulaCore) is the instant it must
finish by, and `Deadline.remaining` the time left. `OutboundHTTPClient` uses
it automatically: no attempt waits past it, and no retry sleeps past it.

### Validation

A `body:` or `query:` type that conforms to `Validatable` is checked after
it decodes and before the handler runs:

```swift
struct Signup: Decodable, Validatable {
    let name: String
    let email: String
    let age: Int
    let pets: [Pet]

    func validate(_ v: inout Validation) {
        v.check("name", name, .notBlank, .length(max: 80))
        v.check("email", email, .email)
        v.check("age", age, .range(13...130))
        v.each("pets", pets)          // Pet is Validatable too
    }
}
```

Every failing field is reported at once, as `422 Unprocessable Content`:

```json
{"status": 422, "title": "Unprocessable Content", "detail": "2 fields are invalid",
 "errors": [{"field": "email", "message": "must be an email address"},
            {"field": "pets[1].name", "message": "must not be blank"}]}
```

Decoding and validation answer different questions, and keep different
statuses. A missing key or a string where a number belongs is a 400 from
decoding. A well-formed value that makes no sense is a 422 from validation.
Rules apply in order and the first failure per field wins, so a blank name is
"must not be blank", not also "too short".

The rules:
- `notBlank`, `length(min:max:)`, `email`, `oneOf`, `matches`;
- `range`, `min`, `max`;
- `notEmpty`, `count(min:max:)`;
- `ValidationRule.that(message) { … }` for anything else.

An optional field is checked only when present. `require(_:_:_:)` records a
cross-field condition ("end after start"), and `try value.validated()`
validates anything by hand. With a custom error renderer, the message lists
every field, since the `errors` member belongs to the problem+json shape.

### Roles protect routes

A controller's roles apply to every route below it; a route's roles narrow
further:

```swift
enum AppRole: String, RouteRole { case admin, billing, support }

@Controller("/admin", roles: [AppRole.admin])
struct AdminController {
    @GetRoute("/")                                    // admin
    func index(_ context: RequestContext) -> Response { … }

    @GetRoute("/invoices", roles: [AppRole.billing])  // admin AND billing
    func invoices(_ context: RequestContext) -> Response { … }

    @GetRoute("/tickets", roles: [AppRole.billing, AppRole.support])
    func tickets(_ context: RequestContext) -> Response { … }  // admin AND (billing OR support)
}
```

**Within one declaration the roles are any-of; separate declarations compose
as and.** Roles *add* rather than replace, unlike `pipelines:`. Replacement is
right for lanes, because a route must be able to say "this one is public"; it
is wrong for roles, where the same rule would let a route widen access by
naming a role its controller does not require. Narrowing is the only direction
a route moves on its own.

Your own type rather than strings, so a misspelled role is a compile error
rather than a 403 nobody reports. `RouteRole` needs nothing beyond the
conformance for a `String`-backed enum; the raw value is the name the
principal is asked about, so it has to match what your identity provider
issues — the type buys spelling, not agreement with the IdP.

The check runs before the controller is constructed, so an unauthorised
request never reaches application code, and it answers from the request's
identity state: no credential and a rejected credential are both 401 and
remain distinguishable, a missing role is 403 naming what would have been
enough. Roles on a `.public` route are a build error, because a lane that
establishes no principal can only ever reject:

```
error: 'ping' requires roles but runs on '.public', which establishes no
principal — every request would be rejected.
```

`context.requireRole("admin")` is still there for a check a signature cannot
express — ownership of the specific record being edited, say.

### Middleware lanes

A *lane* is the whole stack for the routes that name it. A module declares the
default lane as a value — `MiddlewareRegistration.lane(.default, [...])` — the
named form declares another, and a route, controller or asset mount opts in
with `pipelines:`:

```swift
// A module holds lane declarations as values; the build plugin finds them.
let assetsLane = MiddlewareRegistration.lane("assets", [RequestLogging()])
let adminLane  = MiddlewareRegistration.lane("admin",  [RequireAdmin()])
```

```swift
@Controller("/admin", pipelines: [.default, "admin"])
struct AdminController { … }
```

Naming a lane alone means *only* that lane runs, which is how a static-asset
route avoids paying for transaction binding and authentication it can never
use. Concatenate with `.default` to get the usual behaviour plus extras.
An empty middleware list still declares the lane. Referencing a lane nobody declared
fails when dispatch is built — at bootstrap, naming the route and the lane,
never as a 500.

Lanes are `PipelineLane` values, and a string literal is one — `"admin"`
above is a lane. Three names are canonical: `.default`, `.authentication`
(establishes identity, rejects nobody) and `.authenticated` (rejects
anonymous). `.public` means explicitly no lanes and needs no declaration of
its own.

### Lanes per route

A route can name its own lanes, which **replace** the controller's rather
than adding to them:

```swift
@Controller("/dashboard", pipelines: [.authenticated])
struct DashboardController {
    @GetRoute("/", pipelines: [.public])   // deliberate, and says so
    func index(_ context: RequestContext) -> Response { … }

    @GetRoute("/admin")                     // inherits [.authenticated]
    func admin(_ context: RequestContext) -> Response { … }
}
```

Replacement is what expresses both directions — a public controller with one
authenticated route, and an authenticated controller with one public route.
Appending could only ever add, so it cannot say "this one is public".

Because replacement can silently drop authentication, a route that narrows
away its controller's security lane without naming `.public` draws a build
*warning*. It is not an error: narrowing is a call the author is entitled to
make. But `.public` is how you say you meant it, which puts the intent in the
declaration instead of a comment beside it — and makes every deliberately
public route under an authenticated controller greppable.

Authorization stays in the handler: `requireRole` / `requireScope` depend on a
value rather than a lane, so no lane declaration can describe them.

Middleware types are composed once, when the dispatch closure is assembled,
so a request pays one call per layer and never the construction of the chain.
The older `registerMiddleware(_:order:)` closure API is gone with the
container; conform a type to `Middleware` and hand it to
`MiddlewareRegistration.lane(_:_:)`, returning early from `handle` rather than
a result enum.

### CORS

```swift
MiddlewareRegistration.lane(.default, [
    CORS(
        allowedOrigins: .exact(["https://app.example.com"]),
        allowedMethods: [.get, .post, .patch, .delete],
        allowedHeaders: .exact([.contentType, .authorization]),
        exposedHeaders: [.eTag],
        allowCredentials: true,
        maxAge: .seconds(600))
])
```

Origins are `.any` (a literal `*`), `.exact(Set<String>)`, or
`.matching { origin in … }` for the cases a set cannot express. Be stricter
than `hasSuffix` in a predicate: `"https://evil-example.com"` ends with
`example.com`, and that mistake is the whole of several CVEs.

`.any` with `allowCredentials: true` is refused at construction, so it fails
at startup rather than in a browser console. Browsers reject
`Access-Control-Allow-Origin: *` on a credentialed request, so the
combination cannot work; the alternative — quietly echoing the caller's
origin instead of `*` — is how "allow any origin" becomes "allow any origin
to act as any signed-in user".

A preflight (`OPTIONS` carrying `Access-Control-Request-Method`) is answered
by the middleware and never reaches the router: `204` with the negotiated
headers, or `403` naming whichever of origin or method was refused. Every
other request passes through and the headers are added to whatever comes
back, error responses included — a 500 a page cannot read is a 500 nobody
can debug. A request with no `Origin` is left entirely alone.

**List `CORS` in every lane that serves a browser.** Dispatch routes first
and then runs the matched route's lane, so a `CORS` in `.default` does not
run for a route that names `pipelines: [.authenticated]`. The preflight still
works — `OPTIONS` matches no route, and the no-match path runs the default
lane — which makes the failure a confusing one: preflight passes, the real
request comes back without `Access-Control-Allow-Origin`.

### Client address

```swift
context.request.remoteAddress   // the raw TCP peer — never spoofable
context.clientAddress           // the real caller, once a proxy is trusted
```

`clientAddress` is `remoteAddress` unless `web.trusted-proxies` names the
peer as a trusted reverse proxy, in which case it is resolved from
`X-Forwarded-For` instead — walked from the hop closest to this process
back to the first untrusted entry, never further. Nothing is trusted by
default. The whole story, including the algorithm and why the default has
to be this strict, is in [client-address.md](client-address.md).

### Rate limiting

```swift
MiddlewareRegistration.lane(.default, [
    RateLimiting(store: limiter.store, quota: .perMinute(120)) { context in
        context.principal?.subject ?? "anonymous"
    }
])
```

The key closure is required: there is no safe universal key, and a limiter
that picks one for you is one whose key you discover during an incident.
Refusals are a `429` in the application's own error format with
`Retry-After`; successes carry `X-RateLimit-*` so a client can pace itself.
List it after `Authentication` if the key reads identity. The whole story,
including why the algorithm is GCRA and why an unreachable store fails open,
is in [rate-limiting.md](rate-limiting.md).

### Compression

```swift
MiddlewareRegistration.lane(.default, [ResponseCompression()])
```

gzip, for clients that asked for it, on bodies worth compressing. Streaming
bodies are compressed incrementally and flushed per chunk, so server-sent
events keep arriving as events.

It declines, on purpose: anything already carrying `Content-Encoding` (a
`StaticAssets` `.br` variant is better than anything computed per request,
and gzip-wrapped brotli helps nobody), `.file` responses (a range is a range
*of the encoded representation*, so compressing after range selection answers
a different question), bodies under `minimumBytes` (gzip has framing overhead
and a floor; below ~1 KiB it reliably makes things bigger), media types not
in `compressibleTypes`, and any result that came out larger than it went in.

A strong `ETag` is weakened to `W/"…"` when a body is compressed, because a
strong validator promises byte-for-byte identity and the gzip of a body is
not the body. `Vary: Accept-Encoding` is set either way — the *uncompressed*
copy is the one that needs it, or a cache hands it to a client that would
have been sent gzip.

gzip only. `deflate` is the trap it has always been: RFC 9110 says the zlib
format, a large minority of servers shipped raw DEFLATE, and clients learned
to guess — a server offering it picks between two wire formats sharing one
name, and every client that sends `deflate` sends `gzip` too. Brotli is worth
adding and needs its own system library, so it is a later additive case.

This is the one part of Alula Web that links a C library: `CAlulaZlib`, a
`systemLibrary` target over the system zlib. Lean images may need the headers
(`zlib1g-dev` on Debian; the official Swift images carry them).

### Bodies

Request bodies are buffered by default, bounded by
`server.max-request-body-bytes`. A handler that takes `body:
RequestBodyStream` is recorded as streaming-bodied in the route table, and
the transport — which asks the table before collecting bytes, exactly as it
already asks `acceptsUpgrade` — pulls chunks through with real backpressure
instead:

```swift
@PostRoute("/import", maxBodyBytes: 2 << 30)
func importArchive(_ context: RequestContext, body: RequestBodyStream) async throws -> Response {
    for try await chunk in body.chunks { try await ingest(chunk) }
    return .noContent
}
```

`MultipartReader` parses `multipart/form-data` pull-based and in constant
memory, with Go's post-CVE-2023-24536 part and header caps; filenames are
hardened down to the `.`/`..` basename edge.

Responses stream the same way. `Response.streaming` hands the producer a
`ResponseBodyWriter` whose `write` suspends until the transport has taken the
chunk, and reports a disconnected client at the next write — so a producer
faster than its reader is slowed by it rather than buffered ahead of it.

### Refusing lost updates

Two clients read a document, both edit it, both save: the second save
silently erases the first. `checkWritePreconditions` refuses the second with
`412` when the client sends back the `ETag` it read:

```swift
@PutRoute("/documents/:id")
func replace(_ context: RequestContext, id: UUID, body: DocumentBody) async throws -> Response {
    guard let current = try await documents.find(id) else { throw HTTPError(.notFound) }
    try context.checkWritePreconditions(etag: EntityTag(String(current.version)), required: true)
    let saved = try await documents.replace(id, with: body, expecting: current.version)
    return try .json(saved).settingHeader(.eTag, EntityTag(String(saved.version)).headerValue)
}
```

`If-Match` compares strongly, and `If-Match: *` passes whenever the resource
exists. `If-Unmodified-Since` is checked only without `If-Match`, and only
when you pass `lastModified:`. `required: true` answers `428` to a write that
sends neither, so leaving the header off does not skip the check. Make the
write itself conditional too (`UPDATE … WHERE version = $1`): the check and
the write are two statements, and another write can land between them.

### Cookies

```swift
response.settingCookie(Cookie(name: "session", value: token))   // HttpOnly + SameSite=Lax by default
request.cookie("session")
Cookie.expiring("session")                                       // deletion
```

`settingCookie` appends rather than replaces, because several cookies means
several headers.

A cookie that carries state — a login, a cart, a notice for the next page —
is a session, and `AlulaSessionsModule` does the loading, the persisting and
the cookie for you: `context.session`, with a store seam and an in-memory
default. See [sessions.md](sessions.md).

### CSRF

```swift
MiddlewareRegistration.lane(.default, [
    Sessions(runtime: sessions.runtime),
    CSRFProtection(),
])
```

`CSRFProtection` refuses a POST, PUT, PATCH or DELETE that does not carry
the session's own token on `X-CSRF-Token`; GET, HEAD, OPTIONS and TRACE are
exempt, per RFC 9110's own definition of safe. `context.requireSession().csrfToken()`
is the value to hand whatever will submit the next request — a hidden form
field, a `<meta>` tag, a JSON response field. A request with no session at
all is left alone: there is no ambient, cookie-carried authority on it to
protect. List it after `Sessions`, the same `SessionReading` ordering rule
`Authentication` follows.

**Guard sign-in too.** Forcing a visitor to sign in as the *attacker* —
"login CSRF" — is a real attack, and `SameSite=Lax` does not stop it: `Lax`
limits which cookies a cross-site POST *sends*, not which cookies its
response may *set*. Nor does a JSON-shaped sign-in body: a `Codable` body
also accepts `application/x-www-form-urlencoded`, which a plain HTML form
on any site can submit with no CORS preflight at all. The defence is the
same token, handed out before there is anyone to sign in:

```swift
@GetRoute("/csrf")                                     // anonymous: mints the token
func csrf(_ context: RequestContext) throws -> CSRFTokenResponse {
    CSRFTokenResponse(csrfToken: try context.requireSession().csrfToken())
}

@PostRoute("/", pipelines: [.default, "csrf"])         // sign-in names the lane
func signIn(_ context: RequestContext, body: SignIn) async throws -> Response { … }
```

Minting the token is a session write, so that GET sets a cookie for an
anonymous visitor; keep it off routes whose point is to store nothing. The
token survives signing in — `Session.signIn(_:)` regenerates the id and
keeps the values — and needs no rotation there: the regenerated id is what
takes the session away from anyone who planted it, and a token is useless
without the cookie it belongs to.

### WebSocket subprotocols and pings

A handler that speaks named subprotocols lists them, most preferred first:

```swift
struct ChatSocket: WebSocketUpgradeHandler {
    var subprotocols: [String] { ["chat.v2", "chat.v1"] }

    func handle(upgraded connection: WebSocketConnection, context: RequestContext) async throws {
        switch connection.subprotocol {
        case "chat.v2": …
        default: …        // "chat.v1", or nil when the client offered neither
        }
    }
}
```

The first one the client also offered in `Sec-WebSocket-Protocol` goes back in
the handshake and arrives as `connection.subprotocol`. When none match, the
handshake names none, and a client that required one closes the socket
itself (RFC 6455 §4.1).

The server pings every socket every 30 seconds and closes one that has not
answered the previous ping. Without that, a client that disappears without a
close frame (a phone losing signal) holds its socket until TCP gives up,
which can take hours. `server.websocket-ping-seconds` sets the interval, and
`0` turns pings off.

### WebSocket origins

CSRF protection exempts a WebSocket handshake, because it is a `GET`, and
CORS does not apply to WebSockets at all. A browser opens a socket to any
origin and sends that origin's cookies, so a socket authenticated from the
session is open to every page its user visits (cross-site WebSocket
hijacking) unless the server checks `Origin`.

`AlulaWebModule` checks it on every upgrade route, before any lane runs. By
default the `Origin` must be the host the request was addressed to; anything
else gets `403`. A handshake with no `Origin` did not come from a browser page
and is allowed. To accept other origins:

```yaml
web:
  websocket:
    allowed-origins: https://app.example.com, https://admin.example.com
```

`*` alone turns the check off. Use it only for sockets that never read a
cookie. Behind a proxy that rewrites `Host` (nginx does by default), put the
proxy in `web.trusted-proxies` so `X-Forwarded-Host` counts, or list the
public origin here.

### Security headers

Every response carries three headers unless configured off:
`X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, and
`Referrer-Policy: strict-origin-when-cross-origin`. `Strict-Transport-Security`
and `Content-Security-Policy` are sent only once configured:

```yaml
web:
  security-headers:
    frame-options: sameorigin          # deny (default) | sameorigin | off
    referrer-policy: no-referrer       # any Referrer-Policy token, or off
    content-type-options: nosniff      # nosniff (default) | off
    hsts-max-age: 31536000s            # absent: no HSTS
    hsts-include-subdomains: true
    hsts-preload: true                 # checked against the preload list's rules
    content-security-policy: "default-src 'self'"
```

This is a policy of the web module, not a middleware, on purpose. A
middleware in `.default` does not run for a route that names its own lanes —
the trap the CORS section above describes — and a missing security header,
unlike a missing CORS header, fails silently. Dispatch applies the policy
after every lane, to every response: errors, 404s and static assets
included.

A header a route set itself wins. A page meant to be framed by its own
origin sets `X-Frame-Options: SAMEORIGIN` on its response, and the
application-wide `DENY` fills in everywhere else. An unrecognized value, an
HSTS modifier with no `hsts-max-age`, or a `preload` the preload list would
refuse fails startup, naming the key.

HSTS is off by default because it cannot be recalled: a browser remembers
it for `max-age`, whatever the server says afterwards. Browsers ignore it
over plain HTTP, so it is sent however this process was reached — behind a
TLS-terminating proxy, Alula sees HTTP while the browser saw HTTPS.

### Redirects

```swift
return .redirect(to: "/projects/\(project.id)")   // 303: the follow-up is a GET
return .redirect(to: "/v2/reports", .permanent)   // 308: same method, and remember it
```

The status is an enum rather than a number, because choosing between the five
codes *is* the feature: `.seeOther` (303) makes the follow-up a GET, which is
what a form POST wants; `.temporary` (307) and `.permanent` (308) repeat the
method and body, which is what moving an endpoint wants and what handling a
POST does not. `.found` (302) and `.movedPermanently` (301) are there because
clients send them, with doc comments saying to prefer the other two. The body
is always empty — no browser shows a 3xx body.

`Response.seeOther` remains as the spelling that reads well beside the
`Set-Cookie` a login writes.

A browser application usually wants "not signed in" to mean "go and sign in",
and that decision belongs in the `ErrorMapper`, which now receives the
request:

```swift
let errorMapper = ErrorMapper { error, context in
    guard (error as? any HTTPErrorRepresentable)?.httpStatus == .unauthorized,
          context.request.headers[.accept]?.contains("text/html") == true
    else { return nil }                     // API callers keep their 401
    return .redirect(to: "/login?next=\(context.returnTo)")
}
```

`context.returnTo` is this request's path and query, percent-encoded to sit
inside a query value — `.urlQueryAllowed` leaves `&` and `=` in place, so a
return path written raw ends the `next` parameter early and the caller comes
back having lost half their query. The `Accept` gate is the load-bearing part
of the example: the same route serves a browser and a script, and redirecting
the script turns a clean 401 into a 200 full of HTML.

A mapping whose status is a redirect renders no error document. The
error-only `ErrorMapper { error in … }` form is unchanged.

### Files, assets and uploads

`serveContent` is a pure function over a `ByteSource` implementing RFC 9110's
conditional and range rules — `If-None-Match`, `If-Modified-Since`,
`If-Range`, suffix ranges, EOF clamping, 416. `FileByteSource` opens once and
`fstat`s the descriptor, which closes the stat-vs-open TOCTOU at the type
level, and reads with `pread` off the cooperative pool.

`AssetMountRegistration.mount(at:root:pipelines:)` mounts a directory: content hashing,
`Accept-Encoding` negotiation against precompressed siblings, per-pattern
cache headers, an SPA fallback, and path containment that resolves before it
compares.

`ResumableUploads` implements tus 1.0 over a `DiskUploadStore` whose recorded
offsets can only be produced by a proof type that performs the `fsync` — the
ordering is unwritable-wrong rather than merely tested.

### Wire format

Response encoding, request decoding, and error bodies are configurable —
`ResponseEncodable` is unusable for most real APIs otherwise:

```yaml
web:
  json:
    key-strategy: snake-case     # snake-case | as-is (default)
    date-strategy: iso8601       # iso8601 (default) | seconds | milliseconds | foundation
    pretty-print: false
  errors:
    format: problem              # problem (default, RFC 9457) | simple
```

Dates default to ISO-8601 rather than Foundation's seconds-since-2001
`Double`, which is nearly always wrong on a wire shared with anything that is
not another Foundation client — and silently so, since the field is present
and numeric, just meaningless to the reader.

Errors default to RFC 9457 `application/problem+json`:

```json
{"status": 404, "title": "Not Found", "detail": "no such user"}
```

`format: simple` keeps the older `{"status", "error"}` shape for clients that
already parse it. For anything else, provide your own `WebCoders` — its
`renderError` is a closure, so an error body need not be JSON at all:

```swift
// A module provides its own coders; the composition root hands them to
// AlulaWebModule, which takes them as its `coders:` parameter.
var coders = WebCoders.default
coders.jsonEncoder.keyEncodingStrategy = .convertToSnakeCase
```

An application that provides its own keeps it; Alula only fills in the gap.
A misspelled `web.*` value fails at startup naming the key, not on the first
request that happens to encode something.

### HTTPS

TLS is off until a certificate and key are named, and on as soon as they are —
there is no separate enable flag to forget:

```yaml
server:
  tls:
    certificate-chain-path: /etc/tls/fullchain.pem
    private-key-path: /etc/tls/privkey.pem
```

Both are PEM; the chain is leaf first, intermediates after. Serving only the
leaf is the usual cause of "works in curl, fails in a browser". Naming one
key without the other fails at startup rather than falling back to
plaintext — a server that was meant to be HTTPS and quietly is not is the
worst of the three outcomes.

Mutual TLS, when clients must present a certificate too:

```yaml
server:
  tls:
    certificate-chain-path: /etc/tls/fullchain.pem
    private-key-path: /etc/tls/privkey.pem
    trust-roots-path: /etc/tls/ca.pem
    client-authentication: require   # none | request | require
```

`request` asks for a certificate, verifies it if one is offered, and serves
clients that decline. `require` rejects the handshake without a trusted one.
Either mode needs `trust-roots-path`; demanding client certificates with
nothing to verify them against is a startup error.

Terminating TLS at nginx or a load balancer instead is equally supported —
leave these keys out and Alula serves plaintext to the proxy. Either way,
`Strict-Transport-Security` is `web.security-headers.hsts-max-age` — see
*Security headers* above. WebSocket
upgrades ride whatever the listener is doing, so `wss://` needs no separate
configuration.

A controller is constructed for each request, from the components the graph
built once at startup, and discarded when its handler returns. So state kept
in a controller's own stored properties lasts one request. What it injects is
shared by every request running at once, which is why those dependencies must
be `Sendable`. The controller type still has to be `Sendable` itself, because
the generated route closure is: an internal struct whose `@Inject` and
`@ConfigValue` dependencies are Sendable gets the conformance implicitly, and
`public` controllers declare it (`public struct UserController: Sendable`). A
non-Sendable controller is a compile error at the generated registration, not
a runtime race.

Testing (§7) needs no socket:

```swift
let client = try TestClient(routes: alulaRoutes(graph))
#expect(await client.get("/users/999").status == .notFound)

let socket = try await client.webSocket("/chat/lobby")   // in-process upgrade
```

## How routing rides the one registration pipeline (§4)

`@Controller` expands like `@Component` — a parameterized initializer over its
`@Inject`/`@ConfigValue` properties — plus one **route factory per mapped
method**, each of which builds the controller and runs one method as a
`RouteRegistration` value. The route table is not a parallel mechanism: the
composition root's `alulaRoutes(_:)` calls those factories, `AlulaWebModule`
validates the resulting values (conflicts and malformed patterns fail startup,
naming both declaration sites) and builds the dispatch closure handed to the
active transport. The controller itself is a scanned component, so it shows on
an Actuator dashboard like any other.

The build plugin side is Alula Core's existing `AlulaRegistrationPlugin`,
generalized by one word: its scanner recognizes `@Controller` alongside
`@Component` (a name-level change — Core references no Alula Web types), so the
generated composition root's `alulaRoutes(_:)` covers controllers, and route
existence + path-pattern validity are compile-time information (`@GetRoute`
rejects non-literal and malformed paths at the declaration site).

### Base paths (`@Controller("/users")`)

`@Controller` takes an optional base path, combined with every mapped
method's own path the same way Spring combines a class-level
`@RequestMapping` with its method-level mappings — concatenated, collapsing
a doubled `/` at the seam, with a bare `@GetRoute("/")` resolving to the
base path itself rather than a trailing-slash variant of it:

```swift
@Controller("/users")
struct UserController {
    @GetRoute("/")          // → GET /users
    func index(_ context: RequestContext) -> [User] { ... }

    @GetRoute("/:id")       // → GET /users/:id
    func show(_ context: RequestContext) -> User { ... }
}
```

The combination happens once, at macro-expansion time — the generated
`RouteRegistration` carries the already-joined literal, so there's no
runtime string concatenation and no cost over writing the full path by hand.
Duplicate-route detection runs on the combined path, so two methods that
only collide once the base folds in are still caught as a compile error, and
the diagnostic names the full route. Omitted (or `nil`) — the default — is
unprefixed, exactly as before; every controller written before this existed
is unaffected.

## Design deltas from the doc

Recorded here the way Core records its spec deviations in SPIKE-FINDINGS:

1. **`Response.upgrade` carries an `UpgradeResponse`, not a bare handler.**
   The doc's `case upgrade(handler: any ConnectionUpgradeHandler)` gives the
   transport no way to supply the `RequestContext` the handler's own
   signature requires (and a context payload would make `Response` and
   `RequestContext` mutually recursive). `UpgradeResponse` pairs the handler
   with a router-built `run` closure that has the context captured; the
   transport still sees neither routing nor contexts.
2. **Per-request state rides `RequestContext`, not a per-request scope.** The
   design doc scoped per-request state to a `Container` scope opened with
   `Container.withScope`, whose lifetime is its body — but streaming bodies and
   upgraded connections legitimately outlive the dispatch call. The composition
   migration removed the container and its scopes: per-request state is now a
   typed value on `RequestContext` (`identity`, and whatever a middleware
   attaches), which the request's last reference — context, stream, or
   connection handler — keeps alive exactly as long as it is needed, with no
   closed-scope trap mid-SSE.
3. **Per-request values live on `RequestContext` directly, not behind a
   resolver.** The design doc gave `RequestContext` a `resolve(_:qualifier:)`
   backed by the per-request container scope. With the container gone there is
   nothing to resolve against: components take what they need through `@Inject`
   at composition, and a handler reads per-request values such as `identity`
   straight off the typed `RequestContext`. The doc's `scope` field has no
   analogue and needs none.
4. **`runMiddleware` returning early on `.respond`** means the terminal
   routing middleware *returns* the matched handler's response (and also
   records it in `context.response`); a chain that completes without
   answering yields `context.response`, which starts as 404.
5. **HTTP/2 is deferred.** v1 of `AlulaTransport` builds HummingbirdCore's
   HTTP/1.1 channel (keep-alive/pipelining); h2 needs a TLS configuration
   surface Alula doesn't define yet. Nothing in the `ServerTransport`
   contract is version-shaped — h2 lands inside the transport without
   touching the seam.
6. **Middleware registration mechanism.** The doc specifies the chain (§3)
   but not how apps contribute to it. A module declares a lane as a value —
   `MiddlewareRegistration.lane(_:_:)`, an ordered list of `Middleware`
   instances the build plugin scans — composed once; the list gives the order
   within a lane, and module order composes contributions across modules.
   `registerMiddleware(_:order:_:)` was the first spelling and is gone with the
   container.
7. **WebSocket ping/pong frames are transport-internal on the default
   transport.** HummingbirdCore auto-answers pings and does not surface
   them, so `WebSocketFrame.ping`/`.pong` are never *delivered* through
   `WebSocketConnection.frames` there (sending them works). A synthesized
   `.close` frame precedes the stream finishing, so handlers behave
   identically on the in-memory transport and the wire.
8. **A refused WebSocket handshake answers 400 + connection close on the
   default transport.** Routing and middleware still decide the refusal
   (dispatch runs before the upgrade decision, §6.1), but HummingbirdCore
   writes its own fixed refusal response — the routed status (404, 401, …)
   is not writable through that seam. In-process (`TestClient.webSocket`)
   surfaces the routed status; plain HTTP requests to the same path get the
   routed response on the wire as normal.
9. **Inbound WebSocket frames pull; they are not buffered.**
   `WebSocketConnection.frames` is a `WebSocketFrames` sequence that reads one
   message per demand, so a handler that has not asked for the next frame is
   not draining the socket and TCP slows the peer down. It used to be an
   `AsyncStream` fed by a pump running as fast as the peer could send, whose
   buffer is unbounded: `maxWebSocketFrameBytes` caps each message and says
   nothing about how many are queued, so a fast client against a slow handler
   grew this process's memory with no limit. The bound is now
   `webSocketReadAhead × maxWebSocketFrameBytes` per connection, defaulting to
   one message of read-ahead — enough for the pump to fetch the next message
   while the handler works on the current one, which is also what keeps a
   peer's close noticed promptly.

   The trade is that a slow handler now presents as a slow *client* rather
   than as memory growth. That is the right way round: one is a bug report,
   the other is an outage. `WebSocketConnection.init(frames: AsyncStream<…>)`
   still exists for in-memory harnesses, and carries the buffer it always did.

## Layout

```
Sources/Web/AlulaWeb/             runtime: context, middleware, router, response
                               encoding, SSE, upgrade hook, transport seam,
                               AlulaWebModule, macro declarations
Sources/Web/AlulaWebMacrosImpl/   compiler plugin: Controller + mapping markers
Sources/Web/AlulaTransport/       the default transport wrapping HummingbirdCore (§5.2, §5.6)
Sources/Web/AlulaWebTesting/      §7 test-support surface
Tests/Web/AlulaWebTests/          runtime suites (swift-testing)
Tests/Web/AlulaWebMacroTests/     §4 macro fixtures (XCTest, normative expansions)
Tests/Web/AlulaTransportTests/    real-socket HTTP/SSE/WebSocket integration
```

### Connection timeouts

`server.idle-timeout-seconds` (default 60, `0` disables) bounds a connection
that is not getting on with a request. Two things count as that, and neither
is a slow *response*:

- a connection between keep-alive requests, and
- a connection that has started a request — or not even finished its first
  header block — and stopped.

The second is the one that matters. A client holding many connections open,
trickling a byte occasionally and never completing a header block, is the
slowloris shape, and each such connection used to be held until the OS gave
up, roughly four minutes.

It takes two mechanisms because HummingbirdCore's own idle handler is
installed from the upgrade channel's not-upgrading completion handler, which
does not run until a head has decoded — so Alula adds a header-read timeout
in front of it for the window before that. One setting drives both.

**A long response is never affected.** Both bounds disarm once a request is
fully read, so a large download, an SSE stream and an upgraded WebSocket run
as long as they like. That is what makes a default safe.

## Deliberately not here (§10)

No HTTP/2 or HTTP/3 (HummingbirdCore supports HTTP/2 and the builder seam
would take it; nothing here has needed it yet), no templating/SSR (a future
consumer of the upgrade hook), no persistence
(Alula Data), no runtime route-registration API (routes are the macro path;
a hand-built `RouteRegistration` value is the escape hatch beside it, exactly
as a hand-written component sits beside `@Component`), and **no hand-rolled HTTP
parsing** — `AlulaTransport` wraps HummingbirdCore rather than reimplementing
HTTP/1.1 correctness, request-smuggling mitigations, and WebSocket protocol
handling; Alula owns routing and dispatch, not byte-level protocol work.
Vapor remains out of scope as a category mismatch (§5.1) — a full framework,
not a transport.
