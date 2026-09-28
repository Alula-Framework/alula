# Alula OpenAPI

An OpenAPI 3.1 document for your application, generated at build time from
the same scan that builds the route table. There is nothing to annotate. The
route table and the document's routes come from one source, so the methods,
paths and static request and response types cannot drift apart.

What a handler decides at runtime is beyond what a scan can see: the status
of a `Response`-returning handler, which of several responses it chose, a
type's custom `encode(to:)`, and what middleware adds or refuses. See
*Where it cannot see* below.

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

The build says where the document is incomplete, at the route, when the
application includes `AlulaOpenAPIModule`:

- **ALU-OAPI-3001** (warning): a type the route takes or returns has no
  schema — declared outside the scanned targets, or an enum with associated
  values or a generic type. The document names it and describes nothing.
- **ALU-OAPI-3002** (warning, off by default): a handler returns `Response`.
  Most do that to choose a status, so it is opt-in:

  ```yaml
  openapi:
    warn-undocumented-responses: true
  ```

  A handler that deliberately answers with a redirect or a file says so with
  a comment above it, and the warning stays quiet:

  ```swift
  // alula:undocumented-response — a PDF download.
  @GetRoute("/:id/pdf")
  func pdf(_ context: RequestContext, id: String) async throws -> Response
  ```

The document is validated with `openapi-spec-validator` against the demo
application in alula-cli.

Middleware does not appear in it either: see
[interactions.md](interactions.md#what-the-openapi-document-cannot-promise).

## Publishing

In development and test it is served. Anywhere else it needs
`openapi.enabled: true`. A full description of every route and payload is
as useful to someone probing the service as to its clients, so publishing it
should be a decision. To serve it behind authentication, put the path under a
lane in front of the module's route.
