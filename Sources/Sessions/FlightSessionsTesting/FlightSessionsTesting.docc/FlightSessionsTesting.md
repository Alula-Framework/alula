# ``FlightSessionsTesting``

A session store that remembers what was done to it.

## Overview

``RecordingSessionStore`` serves from a dictionary and records every `load`,
`save` and `delete`, so a test can assert on what a request did to its
session rather than only on what came back:

```swift
let store = RecordingSessionStore()
let client = try TestClient(
    routes: LoginController.flightRoutes { _ in LoginController() },
    middleware: try FlightSessionsModule(configuration: config, store: store).middleware)

let response = await client.post("/login", body: form)
let id = try #require(store.storedIDs.first)
#expect(try store.record(for: id)?.values["user"] != nil)
```

`misbehave()` makes every subsequent call throw — a downed store — which is
the path behind the middleware's 503.

## Topics

- ``RecordingSessionStore``
