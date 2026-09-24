# ``AlulaOpenAPI``

An OpenAPI 3.1 document for the application, derived at build time from the
routes and types the build plugin already scans.

## Overview

List the module:

```swift
await Alula.run(
    configuration: try .load(),
    modules: [AlulaWebModule<AlulaTransport>.self, AlulaOpenAPIModule.self, AppModule.self],
    composedBy: alulaComposeModules)
```

`GET /openapi.json` then describes every `@Controller` route: its path
parameters, the `query:` struct's fields, the `body:` type and the return
type, with component schemas for the structs and string enums they name.
There is nothing to annotate and nothing that can drift, because the document
comes from the same scan that builds the route table.

It is served in development and test. Anywhere else, set
`openapi.enabled: true` to publish it.

## Topics

- ``AlulaOpenAPIModule``
- ``OpenAPIDocument``
