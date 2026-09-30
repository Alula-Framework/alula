# ``AlulaConfigCore``

Where configuration values come from, before anything decodes them.

## Overview

``ConfigSource`` is the seam: something that can produce values for keys.
`AlulaConfig` layers sources and decodes into typed structures; this module
is the layer underneath, and it is separate so a component can read
configuration without depending on the decoding machinery.

The shipped sources are ``YAMLConfigSource`` and
``EnvironmentVariablesSource``, in that precedence — a file for the defaults,
the environment for whatever the deployment overrides.

## Environment substitution has a policy

A YAML value like `${DATABASE_URL}` is substituted from the environment, and
``EnvironmentSubstitutionPolicy`` decides what happens when the variable is
not set. Failing loudly at load is the useful behaviour: a database URL that
silently became the empty string produces a connection error much later and
much further from the cause.

## Environments

``AlulaEnvironment`` is the development/staging/production distinction that
decides which files load and which defaults apply. An unset `ALULA_ENV`
resolves to ``AlulaEnvironment/dev`` for choosing the overlay, but
developer-only surfaces — the OpenAPI document, the actuator dashboard, mail
logged instead of sent — need the environment to have been *stated*: that is
`AlulaConfig`'s `Configuration.isExplicitlyDevelopment()`, and
``AlulaEnvironment/isDevelopment`` is the allowlist it applies.

``AlulaConfigFiles`` names the file layering convention so a deployment does
not have to guess which of `alula.yaml` and `alula-prod.yaml` wins.
``ConfigPrefix`` changes the `alula` in those names and in `ALULA_*`
variables, for two applications sharing one environment, and
``ConfigKeyNaming`` is the camelCase-to-kebab-case rule `@Settings` uses to
derive a key from a property name.

## Testing

``TestConfigSource`` supplies values from a dictionary, so a test can
configure a component without a file on disk or an environment variable
leaking between tests.

## Topics

### The seam

- ``ConfigSource``
- ``ConfigDecodable``

### Sources

- ``YAMLConfigSource``
- ``EnvironmentVariablesSource``
- ``TestConfigSource``

### Environments and files

- ``AlulaEnvironment``
- ``AlulaConfigFiles``
- ``ConfigPrefix``
- ``ConfigKeyNaming``
- ``EnvironmentSubstitutionPolicy``

### Parsing

- ``AlulaYAMLDocument``

### Failure

- ``ConfigError``
- ``ConfigLoadError``
