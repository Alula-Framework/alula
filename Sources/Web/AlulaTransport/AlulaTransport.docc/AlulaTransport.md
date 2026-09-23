# ``AlulaTransport``

The shipped HTTP server transport: HummingbirdCore behind
`AlulaWeb`'s `ServerTransport` seam.

## Overview

Nothing in `AlulaWeb`'s API mentions this module. A controller, a route, a
middleware and a `Request` are all expressible without knowing which server
is listening — which is what makes `AlulaWebTesting`'s in-memory transport
possible, and what would make a different server a configuration change
rather than a rewrite.

``AlulaTransport`` is the production answer to that seam:

```swift
await Alula.run(
    configuration: try Configuration.load(),
    modules: [AlulaWebModule<AlulaTransport>.self, AppModule.self],
    composedBy: alulaComposeModules
)
```

## Configuration

``AlulaTransportConfiguration`` covers the host, the port, and TLS. TLS is
configured with a certificate and key path; a malformed pair fails at startup
with ``TLSConfigurationError`` rather than at the first handshake, which is
the point of validating it during bootstrap.

## Topics

### The transport

- ``AlulaTransport``
- ``AlulaTransportConfiguration``
- ``TLSConfigurationError``
