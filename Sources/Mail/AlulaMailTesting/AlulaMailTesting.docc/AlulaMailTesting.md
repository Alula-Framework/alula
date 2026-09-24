# ``AlulaMailTesting``

A transport that records instead of sending.

## Overview

```swift
let transport = RecordingMailTransport()
let mailer = Mailer(transport: transport, defaultFrom: try MailAddress("app@example.com"))
try await PasswordReset(mailer: mailer, jobs: harness.queue).request(for: ada, link: link)
await harness.drain()
#expect(transport.sent.first?.subject == "Reset your password")
```

`fail(with:)` makes the next sends throw, to walk a queued delivery through
its retries.

## Topics

- ``RecordingMailTransport``
