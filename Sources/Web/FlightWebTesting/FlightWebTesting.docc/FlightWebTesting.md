# ``FlightWebTesting``

Testing a Flight application at three sizes, none of which need a port.

## Overview

The reason a controller is a type with injected dependencies rather than a
closure on an application object is that it can be tested three different
ways, and you pick the smallest one that answers the question.

**A controller on its own.** No container, no routing, no server — construct
it and call the method. This is the default, and most controller tests should
stop here:

```swift
@Test func returnsTheOrder() async throws {
    let controller = OrderController(orders: StubOrderService(orders: [order]))
    let found = try await controller.show(
        .mock(pathParameters: ["id": order.id.uuidString]))
    #expect(found.id == order.id)
}

@Test func rejectsAMalformedID() async throws {
    let controller = OrderController(orders: StubOrderService())
    await #expect(throws: HTTPError.self) {
        try await controller.show(.mock(pathParameters: ["id": "nope"]))
    }
}
```

A handler returns its domain value — `show` returns an `Order`, not a
`Response` — so the assertion is on the value, and a failure is a thrown
`HTTPError` rather than a status code. `RequestContext.mock(method:path:headers:body:pathParameters:)`
supplies the context: path parameters, headers and a body when a handler reads
them, nothing when it doesn't.

**Routing and middleware.** ``TestClient`` builds the real dispatch table
from the routes and middleware you hand it — the same `DispatchBuilder` the
server uses, route validation included — and answers requests in-process. A
route factory constructs the controller per request, so a stubbed dependency
is just a value passed in:

```swift
let client = try TestClient(routes: [
    OrderController._flightRoute_show_0 { _ in OrderController(orders: StubOrderService()) }
])
let response = try await client.get("/orders/\(id)")
#expect(response.status == .ok)
```

**The whole application, without a socket.** ``InMemoryTransport`` conforms
to `ServerTransport`, so `FlightWebModule` boots against it and every layer
runs — bootstrap, module ordering, middleware, dispatch — with requests
delivered through memory instead of TCP.

## Stubbing a dependency

There is no container to override: you construct the component under test (or
its route, through the macro-generated factory) with the fake passed to its
initializer. A component takes what it needs as `@Inject` parameters, so
`OrderController(orders: StubOrderService())` is the whole of it — no
conditional wiring inside production code, no `#if DEBUG`.

## WebSockets

``InMemoryWebSocket`` is the socket side of the same idea, and
``InMemoryTransportHub`` connects a test's client end to the application's
server end. Channel joins, broadcasts and disconnects are all exercisable
without a browser or a port.

## Inspecting a response

Everything `TestClient` returns is an ordinary `Response`, so a test asserts on
it directly — status, headers, and body:

```swift
let response = await client.get("/orders/\(id)")

#expect(response.status == .ok)
#expect(response.header("content-type")?.contains("application/json") == true)
#expect(response.header("x-request-id") != nil)
#expect(response.headerValues("set-cookie").count == 2)

let order = try response.decodeJSON(OrderPayload.self)
#expect(order.total == 1250)
```

`Response.header(_:)` and `Response.headerValues(_:)` exist because
`HTTPFields` is keyed by `HTTPField.Name`: the well-known headers have statics
(`headers[.contentType]`), but an application's own header needed
`headers[HTTPField.Name("x-request-id")!]` — a force-unwrap inside an
assertion. Use `headerValues` for headers that may legitimately repeat, since
`header` shows only the first.

For the body, decode into a type that describes the wire shape rather than
reusing the entity: an entity with associations is `Encodable` but deliberately
not `Decodable`, because once an unloaded association has crossed the wire as
`null`, "not loaded" and "loaded and empty" are indistinguishable. A small
`OrderPayload: Decodable` in the test file both solves that and states what the
endpoint is *supposed* to return.

## Topics

### Testing routes

- ``TestClient``

### Testing the whole application

- ``InMemoryTransport``
- ``InMemoryTransportHub``

### WebSockets

- ``InMemoryWebSocket``
