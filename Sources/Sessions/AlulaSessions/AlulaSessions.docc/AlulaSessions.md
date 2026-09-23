# ``AlulaSessions``

Server-side session state: the store seam, the session a handler works with,
and the in-memory store that is the default.

## Overview

A session is a bag of values kept on the server under an id that a cookie
carries. ``Session`` is what a handler sees — read and write values, flash a
notice for the next request, ``Session/regenerate()`` on login,
``Session/destroy()`` on logout:

```swift
let session = try context.requireSession()
try session.set("cart", cart)
session.regenerate()                      // on login: a new id, the same values
try session.flash("notice", "Saved.")    // for the page you redirect to
```

Where the values are kept is ``SessionStore``: three methods over opaque
bytes, and every one of them throws. A cache that fails is answered by the
computation behind it; nothing is behind a session, so a store that cannot
answer says so and the request is refused rather than quietly treated as
signed out.

``InMemorySessionStore`` is the default: bounded, right for one replica.
`AlulaSessionsValkey` in alula-data implements the seam over Valkey for
deployments with more than one.

This target has no dependencies and no HTTP in it. The middleware, the
cookie, and `context.session` are `AlulaWeb`'s, which depends on this
target the way `AlulaChannels` depends on `AlulaPubSub`.

## Topics

### What a handler uses

- ``Session``
- ``SessionID``

### The seam

- ``SessionStore``
- ``SessionRecord``
- ``SessionCommit``
- ``SessionStoreError``

### The default store

- ``InMemorySessionStore``

### Signing out everywhere

- ``OwnerIndexedSessionStore``
- ``SessionRevocationUnsupported``

### One-time links

- ``OneTimeTokenStore``
- ``InMemoryOneTimeTokenStore``
