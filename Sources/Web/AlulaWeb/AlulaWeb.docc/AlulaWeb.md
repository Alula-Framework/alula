# ``AlulaWeb``

HTTP routing, middleware, and WebSockets — declared on controller types,
resolved at build time.

## Overview

A route in Alula is a method on a type the composition root knows how to build, not
a closure captured on an application object:

```swift
@Controller("/orders")
final class OrderController: Sendable {
    @Inject var orders: OrderService

    @GetRoute("/:id")
    func show(_ context: RequestContext) async throws -> Order {
        let id = try context.pathParam("id", as: UUID.self)   // 400 if it is not one
        guard let order = try await orders.find(id) else {
            throw HTTPError(.notFound, "no order \(id)")
        }
        return order
    }
}
```

That difference is the point of the module. A controller is an ordinary
`Sendable` type with injected dependencies, so it can be constructed in a
test and called directly — no server, no port, no request loop. The routing
table is assembled by the same build plugin that generates the composition root, so a
handler whose dependencies aren't provided is a build error rather than a
404 at 3am.

## Requests and responses

``Request`` is a value: method, path, headers, query and body. It has no
reference to a connection, which is what lets a test construct one. A handler
receives a ``RequestContext``, which carries the request beside the path
parameters the match produced, the caller's ``RequestIdentity``, the session
and the logger.

``Response`` is an enum rather than a builder, so the compiler knows which
cases exist:

```swift
try .json(order, status: .created)      // the application's encoder
.text("ok")
.status(.noContent)
.serverSentEvents { events in ... }     // a text/event-stream
```

Anything conforming to ``ResponseEncodable`` can be returned directly, and
``WebCoders`` decides how a body encodes and decodes. `.json` and `.problem`
default to the coders the application configured, through
``WebCoders/current``, so answering with a status changes nothing else about
the body.

## Errors are part of the contract

Throwing ``HTTPError`` produces an [RFC 9457][] problem-details body, unless
`web.errors.format` chose another shape:

```swift
throw HTTPError(.notFound, "no order \(id)")
```

A domain error conforming to ``HTTPErrorRepresentable`` maps itself, so a
service layer can throw its own errors and the transport translates them at
the edge instead of every handler catching and re-wrapping.

[RFC 9457]: https://www.rfc-editor.org/rfc/rfc9457

## Middleware

``Middleware`` is a type with one method, from a ``RequestContext`` and a
``Next`` to a ``Response``. `@Middleware` makes it a component like any
other, so it can inject its dependencies:

```swift
@Middleware
struct RequestTiming: Middleware {
    @Inject var metrics: MetricsRecorder

    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        let start = ContinuousClock.now
        let response = try await next(context)
        metrics.record(ContinuousClock.now - start)
        return response
    }
}
```

Order is declared in one place, outermost first, by the module that holds the
middleware values, and the chain is composed once at startup rather than per
request:

```swift
// In a module whose initializer took `timing: RequestTiming`.
let middleware = MiddlewareRegistration.lane(.default, [timing, authentication])
```

A ``PipelineLane`` names an alternative stack that routes opt into with
`pipelines:` on a controller or a route — how a static-asset route avoids
paying for authentication it can never use. Naming a lane alone runs *only*
that lane; `[.default, "admin"]` concatenates.

A middleware that refuses a request returns its response from `handle`
without calling `next`.

## WebSockets and streaming

``WebSocketRoute(_:pipelines:roles:)`` upgrades a route; the handler receives a
``WebSocketConnection`` and owns it for the connection's lifetime.
``ServerSentEvent`` and ``ServerSentEventWriter`` cover the one-directional
case, which is usually what a dashboard actually needs.

For channels — named topics, presence, and a browser client — see
`AlulaChannels`, which is built on this module rather than beside it.

## The transport is a seam

``ServerTransport`` is the protocol an HTTP server implements;
``AlulaWebModule`` is generic over it. The shipped transport is built on
HummingbirdCore, and nothing in this module's API mentions it. That is what
makes a transport swappable and what makes `AlulaWebTesting` able to run a
whole application without binding a port.

## Topics

### Controllers and routes

- ``Controller(_:pipelines:roles:)``
- ``GetRoute(_:maxBodyBytes:pipelines:roles:timeout:)``
- ``PostRoute(_:maxBodyBytes:pipelines:roles:timeout:)``
- ``PutRoute(_:maxBodyBytes:pipelines:roles:timeout:)``
- ``PatchRoute(_:maxBodyBytes:pipelines:roles:timeout:)``
- ``DeleteRoute(_:maxBodyBytes:pipelines:roles:timeout:)``
- ``WebSocketRoute(_:pipelines:roles:)``
- ``RouteRole``
- ``requireRoles(_:in:)``
- ``PathParameterConvertible``
- ``RequestTimeout``

### Validation

- ``Validatable``
- ``Validation``
- ``ValidationRule``
- ``ValidationFailure``
- ``FieldError``

### Identity

- ``RequestIdentity``
- ``RequestPrincipal``

### Requests and responses

- ``Request``
- ``RequestContext``
- ``Response``
- ``Response/appendingVary(on:)``
- ``ResponseEncodable``
- ``ContentType``
- ``WebCoders``
- ``WebRuntime``
- ``MediaType``
- ``FormDecoder``

### Static assets

- ``AssetMountOptions``
- ``AssetMountRegistration``

### Resumable uploads

- ``UploadStore``
- ``UploadInfo``
- ``DiskUploadStore``
- ``UploadMountOptions``
- ``ResumableUploadError``

### Cookies

- ``Cookie``

### Sessions

- ``Sessions``
- ``AlulaSessionsModule``
- ``SessionEvents``
- ``SessionMetrics``
- ``HTTPEvents``
- ``HTTPMetrics``
- ``CSRFProtection``
- ``CSRFError``
- ``SessionSettings``
- ``SessionConfigKey``
- ``SessionRuntime``
- ``SessionReading``
- ``RequestContext/requireSession()``
- ``DispatchBuilder/SessionOrderError``
- ``SessionUnavailableError``
- ``SessionNotConfiguredError``
- ``SessionConfigurationError``

### Client address

- ``PeerAddress``
- ``TrustedProxies``
- ``RequestContext/clientAddress``
- ``Request/remoteAddress``
- ``TrustedProxiesError``
- ``TrustedProxiesConfigKey``

### Rate limiting

- ``RateLimiting``
- ``RateLimitFailurePolicy``

### Cross-origin requests

- ``CORS``
- ``AllowedOrigins``
- ``AllowedHeaders``

### Security headers

- ``SecurityHeaders``
- ``SecurityHeadersConfigKey``
- ``SecurityHeadersConfigurationError``

### Compression

- ``ResponseCompression``
- ``ContentEncoding``
- ``CompressionLevel``

### Redirects

- ``Response/redirect(to:_:)``
- ``Response/Redirect``
- ``RequestContext/returnTo``

### Request bodies

- ``RequestBodyStream``
- ``BodyStreamLimitError``
- ``MultipartReader``
- ``MultipartPart``
- ``MultipartLimits``
- ``MultipartError``

### Serving sized content

- ``serveContent(for:_:)``
- ``ContentDescriptor``
- ``ByteSource``
- ``FileByteSource``
- ``DataByteSource``
- ``ByteSourceError``
- ``FileResponse``
- ``EntityTag``
- ``ContentHashCache``
- ``HTTPDate``

### Errors

- ``HTTPError``
- ``HTTPErrorRepresentable``
- ``UnsupportedMediaTypeError``
- ``ProblemDetails``
- ``SimpleErrorBody``
- ``BodyDecodingError``
- ``WebCodersError``
- ``ErrorMapper``

### Middleware

- ``Middleware``
- ``Next``
- ``PipelineLane``
- ``MiddlewareRegistration``

### Routing internals

- ``Router``
- ``RoutePattern``
- ``RouteMatch``
- ``RouteRegistration``
- ``Dispatch``
- ``DispatchBuilder``
- ``RouterError``
- ``RoutingError``
- ``compose(_:around:)``
- ``errorResponse(for:context:)``
- ``decodePathParameter(_:named:from:)``
- ``decodeQuery(_:from:)``

### Streaming and upgrades

- ``ServerSentEvent``
- ``ServerSentEventWriter``
- ``ResponseBodyWriter``
- ``WebSocketConnection``
- ``WebSocketOrigins``
- ``UpgradeResponse``
- ``WebSocketFrames``
- ``WebSocketUpgrade``
- ``UpgradeKind``
- ``WebSocketUpgradeHandler``
- ``WebSocketFrame``
- ``WebSocketCloseCode``
- ``WebSocketError``

### Hosting

- ``AlulaWebModule``
- ``ServerTransport``
- ``ServerTransportConfiguration``
