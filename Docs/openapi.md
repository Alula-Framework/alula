# Alula OpenAPI

An OpenAPI 3.1 document for your application, generated at build time from
the same scan that builds the route table. There is nothing to annotate, and
the document cannot drift from the routes, because it is written by the same
pass that registers them.

## Adding this module

| | |
|---|---|
| **Trait** | `Web` |
| **Product** | `AlulaOpenAPI` |
| **Module** | `AlulaOpenAPIModule.self` |

```swift
await Alula.run(
    configuration: try Configuration.load(),
    modules: [AlulaWebModule<AlulaTransport>.self, AlulaOpenAPIModule.self, AppModule.self],
    composedBy: alulaComposeModules)
```

```yaml
openapi:
  path: /openapi.json       # default
  title: Orders API         # default: app.name
  version: 1.4.0            # default: 0.0.0
  description: Orders and fulfilment.
  enabled: true             # default: dev and test only
```

## What it describes

For every `@Controller` route except WebSocket upgrades, the document holds:

| From the handler | In the document |
|---|---|
| method and path | an operation at `/orders/{id}`, with `operationId` `Controller.method` and a tag per controller |
| `id: UUID` path parameters | path parameters with their types. A `:segment` read from the context is a string, and `**` is `{rest}` |
| `query: OrderFilter` | one query parameter per stored property. An optional property is not required |
| `body: NewOrder` | a JSON request body, plus `400`, and `422` when the type is `Validatable`. A `String` body is `text/plain`, and `Data` is `application/octet-stream` |
| the return type | `200` with its schema. No return value is `204`, `String` is `text/plain`, and `Response` is described only as "a response" |

Component schemas are built from the stored properties of every struct and
class those types name, nested types included:
- `CodingKeys` renames are applied;
- computed and `static` properties are left out;
- optionals are not required;
- `[T]` is an array, and `[String: T]` an object;
- `String`- and `Int`-backed enums are enumerations;
- Hangar's `Loadable<T>` is `T` or `null`.

With `web.json.key-strategy: snake-case`, property names are converted the
way Foundation's encoder converts them. The conversion is tested against
Foundation.

## Where it cannot see

- **A handler returning `Response`.** Its body is built at run time, so the
  build cannot know it.
- **Types from packages the build does not scan**, such as a DTO in a
  dependency that does not use Alula. The schema says so in its
  `description`, rather than guessing.
- **Custom `encode(to:)` implementations.** The document follows stored
  properties, not what a hand-written encoder does with them.
- **Framework routes** (Actuator, uploads, the document itself). They are not
  `@Controller`s.

The document is validated with `openapi-spec-validator` against the demo
application in alula-cli.

## Publishing

In development and test it is served. Anywhere else it needs
`openapi.enabled: true`. A full description of every route and payload is
as useful to someone probing the service as to its clients, so publishing it
should be a decision. To serve it behind authentication, put the path under a
lane in front of the module's route.
