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
configuration error unless `mail.smtp.allow-plaintext-auth` says otherwise.

Only a 5xx rejection of the sender, a recipient or the message is
`MailError.permanent`. Authentication and TLS failures are transient, so mail
queued while a misconfiguration is fixed still goes out once it is.

## Topics

- ``AlulaMailSMTPModule``
- ``SMTPMailTransport``
- ``SMTPSettings``
- ``SMTPConfigurationError``
