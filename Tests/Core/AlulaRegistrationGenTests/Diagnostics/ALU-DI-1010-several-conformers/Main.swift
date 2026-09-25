import AlulaCore

protocol Mailer: Sendable {}

@Service
struct SMTPMailer: Mailer {}

@Service
struct LogMailer: Mailer {}

@Service
struct PasswordReset {
    @Inject var mailer: any Mailer
}
