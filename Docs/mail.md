# Alula Mail

Sending email: password resets, verification links, receipts. It has a
transport seam, an SMTP client, and delivery through the job queue so a
request never waits on a mail server.

## Adding this module

| | |
|---|---|
| **Trait** | none for `AlulaMail`; `SMTP` for `AlulaMailSMTP` |
| **Products** | `AlulaMail`, `AlulaMailSMTP`; `AlulaMailTesting` for tests |
| **Modules** | `AlulaMailModule.self`, plus `AlulaMailSMTPModule.self` for a real server |

```swift
.package(url: "https://github.com/Alula-Framework/alula.git",
         from: "0.39.0", traits: ["Web", "SMTP"]),
```

```swift
await Alula.run(
    configuration: try Configuration.load(),
    modules: [
        AlulaMailSMTPModule.self,
        AlulaMailModule.self,
        AlulaQueueWorkerModule.self,
        AppModule.self,
    ],
    composedBy: alulaComposeModules)
```

```yaml
mail:
  from: "Example <no-reply@example.com>"
  smtp:
    host: smtp.example.com
    port: 587                   # default follows security: 587, 465 or 25
    security: starttls          # starttls | tls | none
    username: apikey
    # password: set ALULA_MAIL_SMTP_PASSWORD, never in the file
    timeout-seconds: 30
```

## Sending

```swift
let message = MailMessage(
    to: [try MailAddress("ada@example.com", name: "Ada")],
    subject: "Reset your password",
    text: "Follow this link within the hour: \(link)",
    html: "<p>Follow <a href=\"\(link)\">this link</a> within the hour.</p>")

try await mailer.sendLater(message, via: jobs)   // from a request
try await mailer.send(message)                    // from a script or a job
```

`sendLater` validates the message, then enqueues a `DeliverMail` job on the
`mail` queue. For the job to run, add the mailer's handler where your other
handlers are:

```swift
struct AppModule: AlulaModule {
    let queueHandlers: [QueueHandler]
    init(graph: AlulaGraph, mailer: Mailer) {
        queueHandlers = [mailer.deliveryHandler, /* … */]
    }
}
```

| What went wrong | What happens |
|---|---|
| The message is malformed (no recipient, a line break in the subject) | `sendLater` throws at once |
| The server refused the sender, a recipient or the message (5xx) | The job is discarded: kept as a dead letter with the reply |
| Anything else: 4xx, timeouts, lost connections, bad credentials, TLS | Retried with backoff for about a day |

Bad credentials count as transient on purpose. Fixing the configuration then
delivers the mail that queued up in the meantime, rather than finding it all
discarded.

## Safety

- **No header injection.** Addresses refuse whitespace, line breaks, commas
  and angle brackets. Subjects and custom header values refuse line breaks.
  The headers a transport depends on (`From`, `To`, `Bcc`, `Content-Type` and
  the rest) cannot be set through `headers`.
- **Bcc stays hidden.** Bcc recipients are sent `RCPT TO` and never appear
  in the message.
- **STARTTLS or nothing.** `security: starttls` refuses a server that does
  not offer STARTTLS, and never falls back to plaintext. Credentials over
  `security: none` are a configuration error unless
  `mail.smtp.allow-plaintext-auth: true`.
- **No transport, no start.** Outside `dev` and `test`, `AlulaMailModule`
  without a transport fails composition. `mail.transport: log` logs mail on
  purpose, for a staging environment with no server.

## What the message looks like

`MIMERenderer` writes RFC 5322 with CRLF line endings:
- quoted-printable bodies;
- `multipart/alternative` when there is both text and HTML;
- `multipart/mixed` around that for attachments;
- RFC 2047 encoded words for non-ASCII subjects and names;
- RFC 2231 for non-ASCII attachment names.

CI checks the result against Mailpit, a real server that requires STARTTLS.

## Testing

`RecordingMailTransport` (AlulaMailTesting) keeps what it is given and can
be told to fail. With `QueueTestHarness` a test walks a queued email through
its retries:

```swift
let transport = RecordingMailTransport()
let mailer = Mailer(transport: transport, defaultFrom: try MailAddress("app@example.com"))
let harness = QueueTestHarness(handlers: [mailer.deliveryHandler])
transport.fail(with: .transient("421 busy"))
try await mailer.sendLater(message, via: harness.queue)
await harness.drain()                 // retrying
harness.advance(by: .seconds(60))
await harness.drain()                 // delivered
```

## Not here yet

- **Provider HTTP APIs** (SES, Postmark, SendGrid). A `MailTransport` over
  `MIMERenderer`'s output is a small adapter for any of them.
- **Templates.** Messages are built in Swift. There is deliberately no
  templating engine in Alula.
- **Connection reuse.** Each send opens one SMTP connection, which is fine at
  transactional volume.
