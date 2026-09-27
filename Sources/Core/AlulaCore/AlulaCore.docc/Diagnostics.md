# Diagnostics

Stable codes for what Alula refuses, and how a package reports its own
failures in the same shape.

## Overview

What the build plugin and the macros refuse, and the startup and exit
failures the framework owns in
``Alula/run(configuration:modules:composedBy:logger:)``, carry a stable code.
It is rendered in the compiler's format, so an IDE attaches it to your line:

```
Sources/App/Checkout.swift:8:17: error: [ALU-DI-1001] no module in this application provides `PaymentClient`
    needed by:
      CheckoutService → PaymentClient
    A module provides a value by holding it as a stored property with a written type.
    help: add the module that owns a `PaymentClient` to `modules:`,
          or have one of your modules hold it: `let value: PaymentClient = …`.
    docs: https://github.com/Alula-Framework/alula/blob/main/Diagnostics/ALU-DI-1001.md
```

A code is never renumbered or reused. Its first digit is its family's:

| Prefix | Area |
|---|---|
| `ALU-DI-1xxx` | Dependency injection and graph construction |
| `ALU-WEB-2xxx` | Controllers, routes, middleware, request binding |
| `ALU-OAPI-3xxx` | OpenAPI generation |
| `HGR-QUERY-4xxx` | Hangar query semantics |
| `ALU-CONFIG-5xxx` | Configuration |
| `ALU-SEC-6xxx` | Security and authentication composition |
| `ALU-CMD-7xxx` | Commands |
| `ALU-LIFE-8xxx` | Lifecycle and module composition |
| `ALU-SCHED-9xxx` | Scheduled jobs |

Each `ALU-` code has a page in the repository's `Diagnostics/` directory —
what it means, why Alula rejects it, common causes, fixes — and `docs:` links
to it. alula-cli prints the same page offline:

```
alula explain ALU-DI-1001
alula explain 1001      # the number alone, when one code has it
alula explain           # every code, by family
```

Hangar's `HGR-QUERY-` codes and alula-data's `ALD-` codes (`ALD-CACHE-`,
`ALD-DATA-`, `ALD-MIGRATE-`) have their pages in those packages'
`Diagnostics/` directories; `alula explain` names the page for them.

## Reporting a failure from your own package

What `Alula.run` prints for an error that ends the application is the error's
description, never its reflected form: the reflected form of a driver's error
can carry a connection URL with its password. Two protocols let an error say
more than that.

**``StartupDiagnostic``** replaces the description with
``StartupDiagnostic/startupDiagnostic`` — what an operator needs, such as the
host and port that refused, and never a credential or a configured value.
``StartupDiagnostic/diagnosticCode`` is `nil` by default; a package that
defines a code for the failure returns it, and the report carries the code and
a link to its page:

```swift
import AlulaCore
import AlulaDiagnostics

public struct DataSourceStartupError: Error, StartupDiagnostic {
    let datasource: String, host: String, port: Int, cause: String

    public var startupDiagnostic: String {
        "datasource '\(datasource)' could not connect at \(host):\(port): \(cause)"
    }
    public var diagnosticCode: DiagnosticCode? { .dataSourceUnreachable }
}

extension DiagnosticCode {
    public static let dataSourceUnreachable = DiagnosticCode(
        "ALD-DATA-1001", "A data source could not connect at startup",
        documentationURL: "https://github.com/Alula-Framework/alula-data/blob/main/Diagnostics/ALD-DATA-1001.md")
}
```

`DiagnosticCode` and its public initializer,
`DiagnosticCode(_:_:_:documentationURL:)`, are in the `AlulaDiagnostics`
product. The arguments are the id, the page's title, the severity (`.error`
unless given) and where the page lives. Use your package's own prefix: the
`ALU-` codes are Alula's, listed in `DiagnosticCode.all` with pages in this
repository, and a code made with this initializer links to the URL you give
instead. Applications leave `diagnosticCode` `nil`.

**``ModuleConfigurationError``** is a marker for the error a module's
configuration check throws when its settings are invalid — a certificate path
with no key, a rate limit of zero. `Alula.run` prints it as ALU-CONFIG-5013
with the error's own message, so a module states the kind of problem without
depending on `AlulaDiagnostics`.

## Topics

### Reporting

- ``StartupDiagnostic``
- ``ModuleConfigurationError``
