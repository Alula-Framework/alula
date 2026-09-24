# ``AlulaMail``

Sending email: a transport seam, a message model that cannot carry an
injected header, and delivery now or through the job queue.

## Overview

```swift
@Service struct PasswordReset {
    @Inject var mailer: Mailer
    @Inject var jobs: JobQueue

    func request(for email: MailAddress, link: URL) async throws {
        try await mailer.sendLater(
            MailMessage(to: [email], subject: "Reset your password",
                        text: "Within the hour: \(link)"),
            via: jobs)
    }
}
```

``Mailer/sendLater(_:via:options:)`` is what a request should use. It
validates the message and enqueues a ``DeliverMail`` job, so the request
neither waits on a mail server nor fails when one is down. Add
``Mailer/deliveryHandler`` to a module's `queueHandlers`. A permanent refusal,
such as a 5xx or a malformed message, discards the job. Anything else is
retried for about a day.

## Transports

``AlulaMailModule`` takes a ``MailTransport`` from whichever module provides
one, such as `AlulaMailSMTPModule` (trait `SMTP`). With none, development and
test log each message with ``LoggingMailTransport``, so a reset link can be
read off the console. Any other environment fails composition, because
password resets silently going to a log is worse than a deploy that refuses
to start. `mail.transport: log` chooses logging on purpose.

## Topics

### Sending

- ``Mailer``
- ``MailMessage``
- ``MailAddress``
- ``MailAttachment``
- ``DeliverMail``

### Transports

- ``MailTransport``
- ``LoggingMailTransport``
- ``MIMERenderer``

### Composition and errors

- ``AlulaMailModule``
- ``MailError``
- ``MailConfigurationError``
