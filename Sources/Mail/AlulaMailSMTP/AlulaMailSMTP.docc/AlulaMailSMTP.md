# ``AlulaMailSMTP``

An SMTP client for `AlulaMail`: STARTTLS or implicit TLS, `AUTH PLAIN` or
`LOGIN`, SMTPUTF8.

## Overview

List ``AlulaMailSMTPModule`` and configure `mail.smtp.*`:

```yaml
mail:
  from: "Example <no-reply@example.com>"
  smtp:
    host: smtp.example.com
    security: starttls        # starttls (587) | tls (465) | none (25)
    username: apikey
```

The password comes from `ALULA_MAIL_SMTP_PASSWORD` or any other secret
source. `security: starttls` refuses a server that does not offer STARTTLS,
rather than carry on in plaintext. Credentials over `security: none` are a
configuration error unless `mail.smtp.allow-plaintext-auth` says otherwise,
and ``SMTPSettings`` built in code get the same rule at send time: the
transport sends no credentials over an unencrypted connection unless
`allowPlaintextAuth` is set, and the send fails as `MailError.transient`.

The module keeps a few long-lived connections that every send shares, with
`RSET` between messages: `mail.smtp.pool-size` (default 4; `0` opens one
connection per message), `mail.smtp.idle-seconds` (30) before an idle one is
closed, and `mail.smtp.messages-per-connection` (100) before one is reopened.
`mail.smtp.timeout-seconds` (30) bounds every exchange, opening included.

Only a 5xx rejection of the sender, a recipient or the message is
`MailError.permanent`. Authentication and TLS failures are transient, so mail
queued while a misconfiguration is fixed still goes out once it is.

## Topics

- ``AlulaMailSMTPModule``
- ``SMTPMailTransport``
- ``SMTPSettings``
- ``SMTPConfigurationError``
